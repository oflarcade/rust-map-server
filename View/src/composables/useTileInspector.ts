import { computed, reactive, ref, watch } from 'vue';
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

const selectedTenantId = ref<string>('11');
const tenantList = ref<TenantConfig[]>(TENANTS);
const hierarchyPanelOpen = ref(false);
const layersPanelOpen = ref(false);
const hierarchyEditorOpen = ref(false);

const currentTenant = computed<TenantConfig>(
  () => tenantList.value.find((t) => t.id === selectedTenantId.value) ?? tenantList.value[0] ?? TENANTS[0],
);

const currentZoom = ref(0);
const mapContainer = ref<HTMLDivElement | null>(null);

let map: Map | null = null;
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
  }

  function cleanup(): void {
    if (map) {
      map.remove();
      map = null;
    }
  }

  async function reloadTenant(): Promise<void> {
    const tenant = currentTenant.value;
    resetMeta(baseMeta);
    resetMeta(boundaryMeta);

    const { baseMeta: b, boundaryMeta: bb, baseUrl, boundaryUrl } =
      await loadMartinTileMetadata(tenant, DEFAULT_MARTIN_URL);
    Object.assign(baseMeta, b);
    Object.assign(boundaryMeta, bb);

    const style = buildInspectorStyle(baseMeta, boundaryMeta, baseUrl, boundaryUrl);

    if (map) {
      map.remove();
      map = null;
    }

    const container = mapContainer.value;
    if (!container) return;

    map = new maplibregl.Map({
      container,
      style,
      center: [tenant.lon, tenant.lat],
      zoom: tenant.zoom,
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
    watch(selectedTenantId, () => {
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
