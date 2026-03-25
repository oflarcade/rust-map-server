import { ref, computed, watch } from 'vue';
import { useQuery, useMutation, useQueryClient } from '@tanstack/vue-query';
import { useTileInspector } from './useTileInspector';
import {
  fetchGeoLevels,
  fetchHdxLevelLabels,
  fetchGeoNodes,
  fetchRawHierarchy,
  createGeoLevel,
  updateGeoLevel,
  deleteGeoLevel,
  createGeoNode,
  updateGeoNode,
  deleteGeoNode,
  collectAssignedPcodes,
  buildNodeTree,
  labelToCode,
  type GeoLevel,
  type GeoNode,
  type GeoLevelCreatePayload,
  type GeoNodeCreatePayload,
  type GeoNodeUpdatePayload,
} from '../api/geoHierarchy';

// ---------------------------------------------------------------------------
// Module-level singletons (shared across all callers)
// ---------------------------------------------------------------------------
const selectedRawPcodes       = ref<Set<string>>(new Set());
const targetNodeId            = ref<number | null>(null);
const targetStatePcode        = ref<string | null>(null);
const selectionMode           = ref<'idle' | 'selecting'>('idle');
/** State pcode focused from raw boundary panel — scrolls/highlights custom tree on the right. */
const focusedStatePcode       = ref<string | null>(null);
/** States manually activated by clicking in the left panel (shown in right custom tree). */
const manualActiveStatePcodes = ref<Set<string>>(new Set());
/** States explicitly dismissed by the user — hidden even if auto-active due to existing nodes. */
const suppressedStatePcodes   = ref<Set<string>>(new Set());
/** Whether country is the root of the custom tree (always true for multi-state tenants). */
const showCountryRoot    = ref(false);
const isMultiStateTenant = ref(false);

export type { GeoLevel, GeoNode, GeoLevelCreatePayload, GeoNodeCreatePayload, GeoNodeUpdatePayload };

export function useGeoHierarchyEditor() {
  const { selectedTenantId, currentTenant } = useTileInspector();
  const qc = useQueryClient();

  const tenantKey = computed(() => selectedTenantId.value);

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------
  const {
    data: rawHierarchy,
    isLoading: rawLoading,
    error: rawError,
  } = useQuery({
    queryKey: computed(() => ['tenant', tenantKey.value, 'hierarchy', 'raw']),
    queryFn: () => fetchRawHierarchy(tenantKey.value),
    enabled: computed(() => !!tenantKey.value),
    refetchOnMount: 'always',
    staleTime: 0,
  });

  const {
    data: geoLevelsRaw,
    isLoading: levelsLoading,
    error: levelsError,
  } = useQuery({
    queryKey: computed(() => ['tenant', tenantKey.value, 'geo-levels']),
    queryFn: () => fetchGeoLevels(tenantKey.value),
    enabled: computed(() => !!tenantKey.value),
  });

  const {
    data: hdxLevelLabelsRaw,
    isLoading: hdxLabelsLoading,
    error: hdxLabelsError,
  } = useQuery({
    queryKey: computed(() => ['tenant', tenantKey.value, 'hdx-level-labels']),
    queryFn: () => fetchHdxLevelLabels(tenantKey.value),
    enabled: computed(() => !!tenantKey.value),
  });

  const {
    data: geoNodesRaw,
    isLoading: nodesLoading,
    error: nodesError,
  } = useQuery({
    queryKey: computed(() => ['tenant', tenantKey.value, 'geo-nodes']),
    queryFn: () => fetchGeoNodes(tenantKey.value),
    enabled: computed(() => !!tenantKey.value),
  });

  const geoLevels = computed<GeoLevel[]>(() => geoLevelsRaw.value ?? []);
  const hdxLevelLabels = computed<string[]>(() => hdxLevelLabelsRaw.value ?? []);
  const geoNodes  = computed<GeoNode[]>(() => geoNodesRaw.value ?? []);

  // ---------------------------------------------------------------------------
  // Dynamic terminology — derive from actual hierarchy data so every tenant
  // sees its own admin labels ("District", "Sub-County", "Préfecture", etc.)
  // ---------------------------------------------------------------------------
  const ADM1_BY_COUNTRY: Record<string, string> = {
    NG: 'State', KE: 'County', UG: 'Region', RW: 'Province',
    LR: 'County', CF: 'Préfecture', IN: 'State',
  };

  /** Human-readable label for the adm2 unit (LGA / District / Sub-County …) */
  const adm2Label = computed<string>(() => {
    for (const s of rawHierarchy.value?.states ?? []) {
      const adm2s = (s as any).adm2s;
      if (adm2s?.length && adm2s[0].level_label) return adm2s[0].level_label as string;
    }
    return 'Area';
  });

  /** Abbreviated form for buttons — "Local Government Area" → "LGA", others as-is */
  const adm2Short = computed<string>(() => {
    const l = adm2Label.value;
    if (l === 'Local Government Area') return 'LGA';
    if (l.length > 14) return l.split(/[\s-]/)[0]; // first word for long labels
    return l;
  });

  /** Human-readable label for the adm1 unit (State / Province / County …) */
  const adm1Label = computed<string>(() => {
    const cc = currentTenant.value.countryCode?.toUpperCase() ?? '';
    return ADM1_BY_COUNTRY[cc] ?? 'State';
  });

  const assignedPcodes = computed<Set<string>>(() => collectAssignedPcodes(geoNodes.value));

  const nodeTree = computed(() => buildNodeTree(geoNodes.value));

  // States that already have nodes → auto-activate so they show in the right panel
  const autoActiveStatePcodes = computed<Set<string>>(() => {
    const s = new Set<string>();
    for (const n of geoNodes.value) s.add(n.state_pcode);
    return s;
  });

  /** All states visible in the custom tree right panel (auto + manually activated, minus suppressed). */
  const activeStatePcodes = computed<Set<string>>(() => {
    const combined = new Set(autoActiveStatePcodes.value);
    for (const p of manualActiveStatePcodes.value) combined.add(p);
    for (const p of suppressedStatePcodes.value) combined.delete(p);
    return combined;
  });

  function activateState(pcode: string) {
    // Un-suppress if previously dismissed
    const sup = new Set(suppressedStatePcodes.value);
    sup.delete(pcode);
    suppressedStatePcodes.value = sup;
    const s = new Set(manualActiveStatePcodes.value);
    s.add(pcode);
    manualActiveStatePcodes.value = s;
    focusedStatePcode.value = pcode;
  }

  /**
   * Called when the user explicitly clicks a state/county in the left panel.
   * If the state has no existing nodes, auto-creates one geo_hierarchy_node per
   * adm2 sub-unit (equivalent to "+Sub-Units → select all → Assign").
   * This commits the county to the geo hierarchy with a real API call so the
   * Geo Hierarchy panel reflects it immediately.
   */
  async function addStateToHierarchy(statePcode: string) {
    activateState(statePcode); // immediate UI activation

    // If nodes already exist for this state, just activate (don't recreate)
    if (geoNodes.value.some(n => n.state_pcode === statePcode)) return;

    const state = rawHierarchy.value?.states?.find((s: any) => s.pcode === statePcode);
    const adm2s: any[] = (state as any)?.adm2s ?? [];
    if (!adm2s.length) return;

    // Collect all adm2 pcodes + adm3+ children (sectors, wards, etc.)
    const allPcodes = new Set<string>();
    for (const adm2 of adm2s) {
      allPcodes.add(adm2.pcode);
      for (const child of (adm2.children ?? []) as any[]) allPcodes.add(child.pcode);
    }

    // Temporarily set selectedRawPcodes and use assignAreasToParent machinery
    selectedRawPcodes.value = allPcodes;
    try {
      await assignAreasToParent(statePcode, null);
    } finally {
      selectedRawPcodes.value = new Set();
    }
  }

  function deactivateState(pcode: string) {
    const sup = new Set(suppressedStatePcodes.value);
    sup.add(pcode);
    suppressedStatePcodes.value = sup;
    const m = new Set(manualActiveStatePcodes.value);
    m.delete(pcode);
    manualActiveStatePcodes.value = m;
    if (focusedStatePcode.value === pcode) focusedStatePcode.value = null;
  }

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'geo-levels'] });
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'geo-nodes'] });
    // exact: true targets only the sidebar hierarchy, not ['hierarchy', 'raw'] (raw panel).
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'hierarchy'], exact: true });
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'geojson'] });
  }

  // ---------------------------------------------------------------------------
  // Level mutations
  // ---------------------------------------------------------------------------
  const createLevelMutation = useMutation({
    mutationFn: (p: GeoLevelCreatePayload) => createGeoLevel(tenantKey.value, p),
    onSuccess: invalidate,
  });

  const updateLevelMutation = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<GeoLevelCreatePayload> }) =>
      updateGeoLevel(tenantKey.value, id, payload),
    onSuccess: invalidate,
  });

  const deleteLevelMutation = useMutation({
    mutationFn: (id: number) => deleteGeoLevel(tenantKey.value, id),
    onSuccess: invalidate,
  });

  // ---------------------------------------------------------------------------
  // Node mutations
  // ---------------------------------------------------------------------------
  const createNodeMutation = useMutation({
    mutationFn: (p: GeoNodeCreatePayload) => createGeoNode(tenantKey.value, p),
    onSuccess: invalidate,
  });

  const updateNodeMutation = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: GeoNodeUpdatePayload }) =>
      updateGeoNode(tenantKey.value, id, payload),
    onSuccess: invalidate,
  });

  const deleteNodeMutation = useMutation({
    mutationFn: (id: number) => deleteGeoNode(tenantKey.value, id),
    onSuccess: invalidate,
  });

  // ---------------------------------------------------------------------------
  // Cross-panel selection coordination
  // ---------------------------------------------------------------------------

  /** Enter LGA selection mode targeting a state — each selected LGA becomes its own node. */
  function enterSelectionModeForArea(statePcode: string) {
    targetNodeId.value    = null;
    targetStatePcode.value = statePcode;
    selectionMode.value   = 'selecting';
    selectedRawPcodes.value = new Set();
  }

  /** Enter LGA selection mode targeting an existing node (merges pcodes into that node). */
  function enterSelectionMode(nodeId: number) {
    targetNodeId.value     = nodeId;
    targetStatePcode.value = null;
    selectionMode.value    = 'selecting';
    selectedRawPcodes.value = new Set();
  }

  function exitSelectionMode() {
    selectionMode.value    = 'idle';
    targetNodeId.value     = null;
    targetStatePcode.value = null;
    selectedRawPcodes.value = new Set();
  }

  function togglePcode(pcode: string) {
    const s = new Set(selectedRawPcodes.value);
    if (s.has(pcode)) s.delete(pcode);
    else s.add(pcode);
    selectedRawPcodes.value = s;
  }

  /** Create one individual GeoNode per selected pcode under a state or parent node.
   *  parentId=null → root nodes under the state; parentId=N → child nodes under node N.
   *  When parentId=null (Province-level), adm3+ sectors are auto-nested under their parent
   *  district node (existing or just-created in the same batch). */
  async function assignAreasToParent(statePcode: string, parentId: number | null = null) {
    // Build pcode → {name, level_label} + sector→parent district pcode from raw hierarchy
    const pcodeInfo = new Map<string, { name: string; level_label: string }>();
    const sectorToDistrictPcode = new Map<string, string>();
    for (const state of rawHierarchy.value?.states ?? []) {
      for (const adm2 of (state as any).adm2s ?? []) {
        pcodeInfo.set(adm2.pcode, { name: adm2.name, level_label: adm2.level_label ?? adm2Label.value });
        for (const child of (adm2.children ?? []) as any[]) {
          pcodeInfo.set(child.pcode, { name: child.name, level_label: child.level_label ?? adm2Label.value });
          sectorToDistrictPcode.set(child.pcode, adm2.pcode);
        }
      }
    }

    // Level cache: label → GeoLevel (pre-seeded from existing levels to avoid duplicates)
    const levelByLabel = new Map<string, GeoLevel>();
    for (const l of geoLevels.value) levelByLabel.set(l.level_label.toLowerCase(), l);

    async function resolveLevel(label: string): Promise<GeoLevel> {
      const key = label.toLowerCase();
      if (levelByLabel.has(key)) return levelByLabel.get(key)!;
      const nextOrder = levelByLabel.size > 0
        ? Math.max(...Array.from(levelByLabel.values()).map(l => l.level_order)) + 1
        : 1;
      const created = await createGeoLevel(tenantKey.value, {
        level_order: nextOrder,
        level_label: label,
        level_code:  labelToCode(label),
      });
      levelByLabel.set(key, created);
      return created;
    }

    if (parentId === null) {
      // Province-level: smart-nest adm3+ items under their parent district node.
      // Pre-seed district pcode → node id from existing nodes.
      const districtPcodeToNodeId = new Map<string, number>();
      for (const n of geoNodes.value) {
        if (n.constituent_pcodes?.length === 1 && n.state_pcode === statePcode) {
          districtPcodeToNodeId.set(n.constituent_pcodes[0], n.id);
        }
      }

      // First pass: create adm2 (district) nodes; capture their ids for adm3 nesting
      const adm2Pcodes = [...selectedRawPcodes.value].filter(p => !sectorToDistrictPcode.has(p));
      const adm3Pcodes = [...selectedRawPcodes.value].filter(p => sectorToDistrictPcode.has(p));

      for (const pcode of adm2Pcodes) {
        const info = pcodeInfo.get(pcode);
        const level = await resolveLevel(info?.level_label ?? adm2Label.value);
        const created = await createGeoNode(tenantKey.value, {
          state_pcode:        statePcode,
          parent_id:          null,
          level_id:           level.id,
          name:               info?.name ?? pcode,
          constituent_pcodes: [pcode],
        });
        districtPcodeToNodeId.set(pcode, created.id);
      }

      // Second pass: create adm3+ nodes nested under their parent district
      for (const pcode of adm3Pcodes) {
        const districtPcode = sectorToDistrictPcode.get(pcode)!;
        const effectiveParentId = districtPcodeToNodeId.get(districtPcode) ?? null;
        const info = pcodeInfo.get(pcode);
        const level = await resolveLevel(info?.level_label ?? adm2Label.value);
        await createGeoNode(tenantKey.value, {
          state_pcode:        statePcode,
          parent_id:          effectiveParentId,
          level_id:           level.id,
          name:               info?.name ?? pcode,
          constituent_pcodes: [pcode],
        });
      }
    } else {
      // Node-level: all selected pcodes go directly under the specified parent
      for (const pcode of selectedRawPcodes.value) {
        const info = pcodeInfo.get(pcode);
        const level = await resolveLevel(info?.level_label ?? adm2Label.value);
        await createGeoNode(tenantKey.value, {
          state_pcode:        statePcode,
          parent_id:          parentId,
          level_id:           level.id,
          name:               info?.name ?? pcode,
          constituent_pcodes: [pcode],
        });
      }
    }
    invalidate();
  }

  async function assignSelectedToNode() {
    if (selectedRawPcodes.value.size === 0) return;
    try {
      if (targetStatePcode.value) {
        await assignAreasToParent(targetStatePcode.value, null);
      } else if (targetNodeId.value) {
        const parent = geoNodes.value.find(n => n.id === targetNodeId.value!);
        if (parent) {
          await assignAreasToParent(parent.state_pcode, targetNodeId.value);
        }
      }
    } catch (e) {
      // Partial failure — some nodes may have been created; refresh so UI is consistent
      invalidate();
      throw e;
    } finally {
      // Always exit selection mode so the user isn't stuck in a broken state
      exitSelectionMode();
    }
  }

  // Clear selection + active states + country root mode when tenant changes
  watch(tenantKey, () => {
    exitSelectionMode();
    focusedStatePcode.value = null;
    manualActiveStatePcodes.value = new Set();
    suppressedStatePcodes.value   = new Set();
    showCountryRoot.value    = false;
    isMultiStateTenant.value = false;
  });

  // When raw hierarchy loads: detect multi-state + auto-activate single-state tenants only.
  // Multi-state tenants (2+ states) only show states that already have nodes (autoActiveStatePcodes)
  // or were explicitly clicked in the left panel. This prevents 15 empty county rows cluttering
  // the custom tree for tenants like Bridge Liberia before any hierarchy is built.
  watch(rawHierarchy, (hierarchy) => {
    if (!hierarchy?.states?.length) return;

    const multi = hierarchy.states.length >= 2;
    isMultiStateTenant.value = multi;

    if (multi) {
      showCountryRoot.value = true; // locked on for country-level tenants
    } else {
      // Single-state tenant: auto-activate the one state so the editor isn't empty
      const s = new Set(manualActiveStatePcodes.value);
      s.add(hierarchy.states[0].pcode);
      manualActiveStatePcodes.value = s;
    }
  });

  function toggleCountryRoot() {
    if (!isMultiStateTenant.value) showCountryRoot.value = !showCountryRoot.value;
  }

  function focusRawState(pcode: string | null) {
    focusedStatePcode.value = pcode;
  }

  return {
    // State
    adm1Label,
    adm2Label,
    adm2Short,
    selectedTenantId: tenantKey,
    selectionMode,
    selectedRawPcodes,
    targetNodeId,
    targetStatePcode,
    focusedStatePcode,
    focusRawState,
    activeStatePcodes,
    activateState,
    addStateToHierarchy,
    deactivateState,
    showCountryRoot,
    isMultiStateTenant,
    toggleCountryRoot,

    // Data
    rawHierarchy,
    rawLoading,
    rawError,
    geoLevels,
    hdxLevelLabels,
    geoNodes,
    nodeTree,
    assignedPcodes,
    levelsLoading,
    hdxLabelsLoading,
    nodesLoading,
    levelsError,
    hdxLabelsError,
    nodesError,

    // Level mutations
    createLevel: (p: GeoLevelCreatePayload) => createLevelMutation.mutateAsync(p),
    updateLevel: (id: number, p: Partial<GeoLevelCreatePayload>) =>
      updateLevelMutation.mutateAsync({ id, payload: p }),
    deleteLevel: (id: number) => deleteLevelMutation.mutateAsync(id),

    // Node mutations
    createNode: (p: GeoNodeCreatePayload) => createNodeMutation.mutateAsync(p),
    updateNode: (id: number, p: GeoNodeUpdatePayload) =>
      updateNodeMutation.mutateAsync({ id, payload: p }),
    deleteNode: (id: number) => deleteNodeMutation.mutateAsync(id),

    // Selection
    enterSelectionMode,
    enterSelectionModeForArea,
    exitSelectionMode,
    togglePcode,
    assignSelectedToNode,
  };
}
