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
  type GeoLevel,
  type GeoNode,
  type GeoLevelCreatePayload,
  type GeoNodeCreatePayload,
  type GeoNodeUpdatePayload,
} from '../api/geoHierarchy';

// ---------------------------------------------------------------------------
// Module-level singletons (shared across all callers)
// ---------------------------------------------------------------------------
const selectedRawPcodes = ref<Set<string>>(new Set());
const targetNodeId      = ref<number | null>(null);
const selectionMode     = ref<'idle' | 'selecting'>('idle');

export type { GeoLevel, GeoNode, GeoLevelCreatePayload, GeoNodeCreatePayload, GeoNodeUpdatePayload };

export function useGeoHierarchyEditor() {
  const { selectedTenantId } = useTileInspector();
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

  const assignedPcodes = computed<Set<string>>(() => collectAssignedPcodes(geoNodes.value));

  const nodeTree = computed(() => buildNodeTree(geoNodes.value));

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'geo-levels'] });
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'geo-nodes'] });
    qc.invalidateQueries({ queryKey: ['tenant', tenantKey.value, 'hierarchy'] });
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
  function enterSelectionMode(nodeId: number) {
    targetNodeId.value = nodeId;
    selectionMode.value = 'selecting';
    selectedRawPcodes.value = new Set();
  }

  function exitSelectionMode() {
    selectionMode.value = 'idle';
    targetNodeId.value = null;
    selectedRawPcodes.value = new Set();
  }

  function togglePcode(pcode: string) {
    const s = new Set(selectedRawPcodes.value);
    if (s.has(pcode)) s.delete(pcode);
    else s.add(pcode);
    selectedRawPcodes.value = s;
  }

  async function assignSelectedToNode() {
    if (!targetNodeId.value || selectedRawPcodes.value.size === 0) return;
    const nid = targetNodeId.value;
    // Get existing constituent_pcodes for the node and merge
    const existing = geoNodes.value.find(n => n.id === nid);
    const existingPcodes = existing?.constituent_pcodes ?? [];
    const merged = Array.from(new Set([...existingPcodes, ...selectedRawPcodes.value]));
    await updateNodeMutation.mutateAsync({ id: nid, payload: { constituent_pcodes: merged } });
    exitSelectionMode();
  }

  // Clear selection when tenant changes
  watch(tenantKey, exitSelectionMode);

  return {
    // State
    selectedTenantId: tenantKey,
    selectionMode,
    selectedRawPcodes,
    targetNodeId,

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
    exitSelectionMode,
    togglePcode,
    assignSelectedToNode,
  };
}
