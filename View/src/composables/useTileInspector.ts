import { computed, reactive, ref, watch } from 'vue';

const LAST_TENANT_STORAGE_KEY = 'newglobe.selectedTenantId';

function readStoredTenantId(): string | null {
  try {
    const v = localStorage.getItem(LAST_TENANT_STORAGE_KEY);
    return v && v.length > 0 ? v : null;
  } catch {
    return null;
  }
}

function persistStoredTenantId(id: string): void {
  try {
    localStorage.setItem(LAST_TENANT_STORAGE_KEY, id);
  } catch {
    /* private mode, etc. */
  }
}

function initialTenantIdFromStorage(): string {
  const stored = readStoredTenantId();
  // The static TENANTS list does not include DB-created tenants (e.g. 22, 23, ...).
  // Keep the stored value; reloadTenantList() will validate/fallback after API load.
  if (stored) return stored;
  return TENANTS[0]?.id ?? '1';
}
import maplibregl, { type Map } from 'maplibre-gl';
import { DEFAULT_MARTIN_URL, DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { TENANTS, loadTenants, type TenantConfig } from '../config/tenants';
import { buildInspectorStyle, loadMartinTileMetadata } from '../map/inspectorStyle';
// Circular ESM imports: these modules import useTileInspector themselves, but calling
// their exported functions here only happens inside function bodies (never at module-init
// time), so the ESM live-binding resolution is safe.
import { useMapInteraction } from './useMapInteraction';
import { useMapLayers } from './useMapLayers';

// ---------------------------------------------------------------------------
// Exported interfaces — defined in src/types/, re-exported here for backwards compat
// ---------------------------------------------------------------------------

import type { DataControlRow } from '../types/map';
import type {
  BoundarySummary,
  HierarchyLGA,
  HierarchyZone,
  HierarchyAdmNode,
  HierarchyChild,
  HierarchyState,
  HierarchyData,
} from '../types/boundary';

export type { DataControlRow } from '../types/map';
export type {
  BoundarySummary,
  HierarchyLGA,
  HierarchyZone,
  HierarchyAdmNode,
  HierarchyChild,
  HierarchyState,
  HierarchyData,
} from '../types/boundary';

// ---------------------------------------------------------------------------
// Module-level shared state (singleton across all callers)
// ---------------------------------------------------------------------------

const selectedTenantId = ref<string>(initialTenantIdFromStorage());
const tenantList = ref<TenantConfig[]>(TENANTS);
const hierarchyPanelOpen = ref(false);
const layersPanelOpen = ref(false);
const hierarchyEditorOpen = ref(false);
const addTenantWizardOpen = ref(false);

const currentTenant = computed<TenantConfig>(
  () => tenantList.value.find((t) => t.id === selectedTenantId.value) ?? tenantList.value[0] ?? TENANTS[0],
);

const currentZoom = ref(0);
const mapContainer = ref<HTMLDivElement | null>(null);

let map: Map | null = null;
let tenantLoadVersion = 0;
const baseMeta = reactive<Record<string, any>>({});
const boundaryMeta = reactive<Record<string, any>>({});

// boundarySummary kept here for backward compatibility — callers that destructure it from
// useTileInspector still work. Authoritative copy is in useMapLayers (manages states/lgas).
const boundarySummary = reactive<BoundarySummary>({
  states: 0,
  lgas: 0,
  stateNames: [],
  lgaNames: [],
  clickedLGA: '',
});

let watcherRegistered = false;

// ---------------------------------------------------------------------------
// Composable
// ---------------------------------------------------------------------------

export function useTileInspector() {

  // -- Internal helpers -----------------------------------------------------

  function resetMeta(target: Record<string, any>) {
    Object.keys(target).forEach((k) => delete target[k]);
  }

  // -- Public functions -----------------------------------------------------

  function resizeMap(): void {
    map?.resize();
  }

  function getMap(): Map | null {
    return map;
  }

  async function reloadTenantList(): Promise<void> {
    const PROXY = normalizeBaseUrl(DEFAULT_PROXY_URL);
    tenantList.value = await loadTenants(PROXY);
    const ids = new Set(tenantList.value.map((t) => t.id));
    if (!ids.has(selectedTenantId.value)) {
      const stored = readStoredTenantId();
      if (stored && ids.has(stored)) selectedTenantId.value = stored;
      else if (tenantList.value[0]) selectedTenantId.value = tenantList.value[0].id;
    }
    persistStoredTenantId(selectedTenantId.value);
  }

  function openAddTenantWizard(): void {
    addTenantWizardOpen.value = true;
  }

  function closeAddTenantWizard(): void {
    addTenantWizardOpen.value = false;
  }

  function cleanup(): void {
    if (map) {
      map.remove();
      map = null;
    }
  }

  async function reloadTenant(): Promise<void> {
    const loadVersion = ++tenantLoadVersion;
    const tenant = currentTenant.value;
    resetMeta(baseMeta);
    resetMeta(boundaryMeta);

    const { baseMeta: b, boundaryMeta: bb, baseUrl, boundaryUrl } =
      await loadMartinTileMetadata(tenant, DEFAULT_MARTIN_URL);
    // Ignore stale loads when tenant changed while async metadata was in flight.
    if (loadVersion !== tenantLoadVersion) return;
    Object.assign(baseMeta, b);
    Object.assign(boundaryMeta, bb);

    const style = buildInspectorStyle(baseMeta, boundaryMeta, baseUrl, boundaryUrl);

    if (map) {
      map.remove();
      map = null;
    }

    const container = mapContainer.value;
    if (!container) return;

    // Prefer source-native viewport (state tiles like nigeria-borno) to avoid blank
    // initial views when tenant defaults are country-level.
    let initialCenter: [number, number] = [tenant.lon, tenant.lat];
    let initialZoom: number = tenant.zoom;
    const c = baseMeta.center;
    if (Array.isArray(c) && c.length >= 3) {
      const [lon, lat, zoom] = c;
      if (Number.isFinite(lon) && Number.isFinite(lat) && Number.isFinite(zoom)) {
        initialCenter = [lon, lat];
        initialZoom = zoom;
      }
    }

    map = new maplibregl.Map({
      container,
      style,
      center: initialCenter,
      zoom: initialZoom,
    });

    map.addControl(new maplibregl.NavigationControl());

    map.on('zoom', () => {
      currentZoom.value = map!.getZoom();
    });

    map.once('load', () => {
      // useMapInteraction is imported at the top — safe to call here because by the time
      // map 'load' fires, all ESM modules have been fully initialised.
      useMapInteraction().initMapInteractions();
      useMapLayers().initControls();
    });

    map.on('idle', () => {
      currentZoom.value = map!.getZoom();
      useMapLayers().updateControlStates();
    });
  }

  // loadHierarchy / loadZoneOverlay: no-op stubs — boundary data is driven by
  // TanStack (useBoundarySearch / useMapLayers). Callers may call these hooks for
  // API compatibility; prefer queryClient.invalidateQueries for manual refresh.
  function loadHierarchy(): void {}

  function loadZoneOverlay(): void {}

  // -- Watcher (registered once) --------------------------------------------

  if (!watcherRegistered) {
    watcherRegistered = true;
    watch(selectedTenantId, (id) => {
      persistStoredTenantId(id);
      reloadTenant();
    });
  }

  // -- Return ---------------------------------------------------------------

  return {
    selectedTenantId,
    tenantList,
    hierarchyPanelOpen,
    layersPanelOpen,
    hierarchyEditorOpen,
    addTenantWizardOpen,
    openAddTenantWizard,
    closeAddTenantWizard,
    currentTenant,
    currentZoom,
    boundarySummary,
    mapContainer,

    reloadTenant,
    reloadTenantList,
    resizeMap,
    getMap,
    loadHierarchy,
    loadZoneOverlay,
    cleanup,
  };
}
