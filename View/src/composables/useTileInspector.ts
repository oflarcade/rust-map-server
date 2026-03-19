import { computed, reactive, ref, watch } from 'vue';
import maplibregl, { type Map } from 'maplibre-gl';
import { DEFAULT_MARTIN_URL, DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { TENANTS, type TenantConfig } from '../config/tenants';
import { buildInspectorStyle, loadMartinTileMetadata, resolveBoundarySourceKey } from '../map/inspectorStyle';

// ---------------------------------------------------------------------------
// Exported interfaces
// ---------------------------------------------------------------------------

export interface DataControlRow {
  id: string;
  group: 'base' | 'boundary';
  label: string;
  layers: string[];
  visible: boolean;
}

export interface BoundarySummary {
  states: number;
  lgas: number;
  stateNames: string[];
  lgaNames: string[];
  clickedLGA: string;
}

export interface HierarchyLGA {
  pcode: string;
  name: string;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
}

export interface HierarchyZone {
  zone_pcode: string;
  zone_name: string;
  name?: string;
  level_label?: string;
  color?: string;
  parent_pcode: string;
  constituent_pcodes: string[];
  zone_level?: number;
  zone_type_label?: string;
  is_zone?: boolean;
  children?: HierarchyChild[];
}

export interface HierarchyAdmNode {
  pcode: string;
  name: string;
  level?: number;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
  is_zone?: false;
  children?: HierarchyAdmNode[];
}

export type HierarchyChild = HierarchyZone | HierarchyAdmNode;

export interface HierarchyState {
  pcode: string;
  name: string;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
  lgas: HierarchyLGA[];
  zones?: HierarchyZone[];
  children?: HierarchyChild[];
}

export interface HierarchyData {
  pcode: string;
  name: string;
  source?: string;
  license?: string;
  state_count?: number;
  lga_count?: number;
  states: HierarchyState[];
}

// ---------------------------------------------------------------------------
// Internal constants
// ---------------------------------------------------------------------------

const BASE_LAYERS = [
  'base-water',
  'base-landcover',
  'base-landuse',
  'base-roads',
  'base-roads-major',
  'base-buildings',
  'base-place-label',
];

// ---------------------------------------------------------------------------
// Module-level shared state (singleton across all callers)
// ---------------------------------------------------------------------------

const selectedTenantId = ref<string>('11');

const currentTenant = computed<TenantConfig>(
  () => TENANTS.find((t) => t.id === selectedTenantId.value) ?? TENANTS[0],
);

const currentZoom = ref(0);
const dataControls = ref<DataControlRow[]>([]);

const boundarySummary = reactive<BoundarySummary>({
  states: 0,
  lgas: 0,
  stateNames: [],
  lgaNames: [],
  clickedLGA: '',
});

const boundarySearch = ref('');
const boundaryHierarchy = ref<HierarchyData | null>(null);
const mapContainer = ref<HTMLDivElement | null>(null);

let map: Map | null = null;
let inspectorPopup: maplibregl.Popup | null = null;
const baseMeta = reactive<Record<string, any>>({});
const boundaryMeta = reactive<Record<string, any>>({});
let allBoundaryFeatures: GeoJSON.Feature[] = [];

let watcherRegistered = false;

// ---------------------------------------------------------------------------
// Composable
// ---------------------------------------------------------------------------

export function useTileInspector() {

  // -- Computed -------------------------------------------------------------

  const baseControls = computed(() =>
    dataControls.value.filter((row) => row.group === 'base'),
  );

  const boundaryControls = computed(() =>
    dataControls.value.filter((row) => row.group === 'boundary'),
  );

  const filteredStateNames = computed(() => {
    const data = boundaryHierarchy.value;
    if (!data) return [];
    const q = boundarySearch.value.toLowerCase().trim();
    if (!q) {
      return data.states.map((s) => s.name).sort((a, b) => a.localeCompare(b));
    }
    return data.states
      .filter((s) => s.name.toLowerCase().includes(q) || s.pcode.toLowerCase().includes(q))
      .map((s) => s.name)
      .sort((a, b) => a.localeCompare(b));
  });

  const filteredLGANames = computed(() => {
    const data = boundaryHierarchy.value;
    if (!data) return [];
    const q = boundarySearch.value.toLowerCase().trim();
    const allLgas = data.states.flatMap((s) => s.lgas);
    if (!q) {
      return allLgas.map((l) => l.name).sort((a, b) => a.localeCompare(b));
    }
    return allLgas
      .filter((l) => l.name.toLowerCase().includes(q) || l.pcode.toLowerCase().includes(q))
      .map((l) => l.name)
      .sort((a, b) => a.localeCompare(b));
  });

  const filteredHierarchy = computed<HierarchyData | null>(() => {
    const data = boundaryHierarchy.value;
    if (!data) return null;

    const q = boundarySearch.value.toLowerCase().trim();
    if (!q) return data;

    const matchedStates = data.states
      .map((state) => {
        const stateMatches =
          state.name.toLowerCase().includes(q) ||
          state.pcode.toLowerCase().includes(q);

        const matchingLgas = state.lgas.filter(
          (lga) =>
            lga.name.toLowerCase().includes(q) ||
            lga.pcode.toLowerCase().includes(q),
        );

        if (stateMatches) return { ...state };
        if (matchingLgas.length > 0) return { ...state, lgas: matchingLgas };
        return null;
      })
      .filter((s): s is HierarchyState => s !== null);

    return { ...data, states: matchedStates };
  });

  // -- Internal helpers -----------------------------------------------------

  function resetMeta(target: Record<string, any>) {
    Object.keys(target).forEach((k) => delete target[k]);
  }

  function bboxFromGeometry(
    geometry: GeoJSON.Geometry,
  ): [[number, number], [number, number]] {
    let minLng = Infinity;
    let minLat = Infinity;
    let maxLng = -Infinity;
    let maxLat = -Infinity;

    function walk(coords: any) {
      if (typeof coords[0] === 'number') {
        if (coords[0] < minLng) minLng = coords[0];
        if (coords[1] < minLat) minLat = coords[1];
        if (coords[0] > maxLng) maxLng = coords[0];
        if (coords[1] > maxLat) maxLat = coords[1];
      } else {
        coords.forEach(walk);
      }
    }

    // @ts-expect-error coordinates is valid for all geometry types here
    walk(geometry.coordinates);
    return [
      [minLng, minLat],
      [maxLng, maxLat],
    ];
  }

  // -- Style builder (HDX filters) ------------------------------------------

  // -- Map interaction setup ------------------------------------------------

  function initMapInteractions() {
    if (!map) return;

    map.on('mouseenter', 'boundary-fill', () => {
      map?.getCanvas().style.setProperty('cursor', 'pointer');
    });

    map.on('mouseleave', 'boundary-fill', () => {
      map?.getCanvas().style.removeProperty('cursor');
    });

    map.on('click', 'boundary-fill', (e) => {
      if (!e.features?.length) return;
      const feature = e.features[0];
      const props = (feature.properties ?? {}) as any;
      const adm2 = props.adm2_name || '';
      const adm1 = props.adm1_name || props.name || '';
      const title = adm2 || adm1;
      const subtitle = adm2 ? adm1 : '';

      if (feature.geometry) {
        const bounds = bboxFromGeometry(feature.geometry as GeoJSON.Geometry);
        map?.fitBounds(bounds, { padding: 60, maxZoom: 14 });
      }
      if (title) {
        boundarySummary.clickedLGA = title;
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '220px' })
          .setLngLat(e.lngLat)
          .setHTML(
            `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">${subtitle ? 'LGA' : 'State'}</div>` +
            `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${title}</div>` +
            (subtitle ? `<div style="font-size:11px;color:#475569;margin-top:3px">${subtitle}</div>` : '')
          )
          .addTo(map!);
      }
    });
  }

  // -- Layer control helpers ------------------------------------------------

  function updateControlStates() {
    if (!map || !map.getStyle()) {
      dataControls.value = [];
      return;
    }
    dataControls.value = dataControls.value.map((row) => {
      const visibleCount = row.layers.filter((id) => {
        if (!map?.getLayer(id)) return false;
        const vis = map.getLayoutProperty(id, 'visibility') ?? 'visible';
        return vis !== 'none';
      }).length;
      return { ...row, visible: visibleCount > 0 };
    });
  }

  function initControls() {
    dataControls.value = [
      { id: 'water', group: 'base', label: 'Water', layers: ['base-water'], visible: true },
      { id: 'landcover', group: 'base', label: 'Landcover', layers: ['base-landcover'], visible: true },
      { id: 'landuse', group: 'base', label: 'Landuse', layers: ['base-landuse'], visible: true },
      { id: 'roads', group: 'base', label: 'Roads', layers: ['base-roads'], visible: true },
      { id: 'roads-major', group: 'base', label: 'Major roads', layers: ['base-roads-major'], visible: true },
      { id: 'buildings', group: 'base', label: 'Buildings', layers: ['base-buildings'], visible: true },
      { id: 'places', group: 'base', label: 'Places', layers: ['base-place-label'], visible: true },
      { id: 'zones', group: 'boundary', label: 'Administrative areas', layers: ['zones-fill', 'zones-outline'], visible: true },
      { id: 'boundary-fill', group: 'boundary', label: 'Boundary areas', layers: ['boundary-fill'], visible: true },
      { id: 'boundary-state', group: 'boundary', label: 'State lines', layers: ['boundary-state-line'], visible: true },
      { id: 'boundary-lga', group: 'boundary', label: 'LGA lines', layers: ['boundary-lga-line'], visible: true },
      { id: 'boundary-ward', group: 'boundary', label: 'Ward/Sector lines', layers: ['ward-outline'], visible: true },
      { id: 'boundary-state-label', group: 'boundary', label: 'State labels', layers: ['boundary-state-label'], visible: true },
      { id: 'boundary-lga-label', group: 'boundary', label: 'LGA labels', layers: ['boundary-lga-label'], visible: true },
    ];
    updateControlStates();
  }

  // -- Public functions -----------------------------------------------------

  function toggleControl(row: DataControlRow): void {
    if (!map) return;
    const nextVisible = !row.visible;
    for (const layerId of row.layers) {
      if (map.getLayer(layerId)) {
        map.setLayoutProperty(layerId, 'visibility', nextVisible ? 'visible' : 'none');
      }
    }
    updateControlStates();
    refreshBoundarySummary();
  }

  function refreshBoundarySummary(): void {
    boundarySummary.states = 0;
    boundarySummary.lgas = 0;
    boundarySummary.stateNames = [];
    boundarySummary.lgaNames = [];

    if (!map || !map.isStyleLoaded() || !map.getLayer('boundary-fill')) return;

    let features: maplibregl.MapGeoJSONFeature[] = [];
    try {
      features = map.queryRenderedFeatures({ layers: ['boundary-fill'] });
    } catch {
      features = [];
    }

    const stateNames = new Set<string>();
    const lgaNames = new Set<string>();
    let states = 0;
    let lgas = 0;

    for (const f of features) {
      const props = (f.properties ?? {}) as any;
      if (props.adm2_name) {
        lgas += 1;
        lgaNames.add(String(props.adm2_name));
      } else if (props.adm1_name) {
        states += 1;
        stateNames.add(String(props.adm1_name));
      }
    }

    boundarySummary.states = states;
    boundarySummary.lgas = lgas;
    boundarySummary.stateNames = Array.from(stateNames).sort((a, b) => a.localeCompare(b)).slice(0, 40);
    boundarySummary.lgaNames = Array.from(lgaNames).sort((a, b) => a.localeCompare(b)).slice(0, 80);
  }

  function zoomToName(name: string): void {
    if (!map) return;
    const features = map.querySourceFeatures('boundary', { sourceLayer: 'boundaries' });
    const match = features.find((f) => {
      const p = (f.properties ?? {}) as any;
      return p.adm1_name === name || p.adm2_name === name || p.name === name;
    });
    if (match?.geometry) {
      const bounds = bboxFromGeometry(match.geometry as unknown as GeoJSON.Geometry);
      map.fitBounds(bounds, { padding: 60, maxZoom: 14 });
    }
  }

  type HighlightItem = { pcode: string; level: 'state' | 'lga' | 'zone'; name?: string };

  const EMPTY_FC: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };

  function setHighlightFeatures(features: GeoJSON.Feature[]) {
    const src = map?.getSource('highlight-overlay') as maplibregl.GeoJSONSource | undefined;
    if (src) src.setData({ type: 'FeatureCollection', features } as any);
  }

  function resetZonePaint() {
    if (map?.getLayer('zones-fill')) map.setPaintProperty('zones-fill', 'fill-opacity', 0);
    if (map?.getLayer('zones-outline')) map.setPaintProperty('zones-outline', 'line-opacity', 1);
  }

  function highlightBoundary(item: HighlightItem | null): void {
    if (!map) return;

    if (!item) {
      setHighlightFeatures([]);
      resetZonePaint();
      return;
    }

    const { pcode, level } = item;

    if (level === 'zone') {
      setHighlightFeatures([]);
      const matchZone: any = ['==', ['get', 'pcode'], pcode];
      if (map.getLayer('zones-fill')) {
        map.setPaintProperty('zones-fill', 'fill-opacity', ['case', matchZone, 0.5, 0]);
      }
      if (map.getLayer('zones-outline')) {
        map.setPaintProperty('zones-outline', 'line-opacity', ['case', matchZone, 1, 0.3]);
      }
      return;
    }

    // state or lga: find geometry in PostGIS GeoJSON features (includes grouped_lga for highlight)
    resetZonePaint();
    const feature = allBoundaryFeatures.find((f) => f.properties?.pcode === pcode);
    setHighlightFeatures(feature ? [feature] : []);
  }

  function highlight(text: string, query: string): string {
    if (!query) return text;
    const idx = text.toLowerCase().indexOf(query.toLowerCase());
    if (idx === -1) return text;
    return (
      text.slice(0, idx) +
      '<mark>' +
      text.slice(idx, idx + query.length) +
      '</mark>' +
      text.slice(idx + query.length)
    );
  }

  async function loadZoneOverlay(): Promise<void> {
    if (!map) return;
    const PROXY = normalizeBaseUrl(DEFAULT_PROXY_URL);
    const tid = selectedTenantId.value;
    try {
      const res = await fetch(`${PROXY}/boundaries/geojson?t=${tid}`, {
        headers: { 'X-Tenant-ID': tid },
      });
      if (!res.ok || !map) return;
      const geojson = await res.json();

      // Store all features for highlight lookups (state, lga, zone all have pcode)
      allBoundaryFeatures = geojson.features ?? [];

      const zoneFeatures = allBoundaryFeatures.filter(
        (f: any) => f.properties?.feature_type === 'zone',
      );
      const zoneCollection = { type: 'FeatureCollection', features: zoneFeatures };

      if (map.getSource('zones-overlay')) {
        (map.getSource('zones-overlay') as maplibregl.GeoJSONSource).setData(zoneCollection as any);
      } else {
        map.addSource('zones-overlay', { type: 'geojson', data: zoneCollection as any });
        // Fill starts hidden — only shown on click
        map.addLayer({
          id: 'zones-fill',
          type: 'fill',
          source: 'zones-overlay',
          paint: {
            'fill-color': ['coalesce', ['get', 'color'], '#a78bfa'],
            'fill-opacity': 0,
          },
        } as any, 'boundary-state-label');
        map.addLayer({
          id: 'zones-outline',
          type: 'line',
          source: 'zones-overlay',
          paint: {
            'line-color': ['coalesce', ['get', 'color'], '#a78bfa'],
            'line-width': ['case', ['==', ['get', 'zone_level'], 1], 2, 1.5],
          },
        } as any, 'boundary-state-label');
      }

      // When zones exist, hide the PMTiles LGA/boundary lines to avoid double outlines
      if (zoneFeatures.length > 0) {
        for (const layerId of ['boundary-fill', 'boundary-lga-line', 'boundary-state-line']) {
          if (map.getLayer(layerId)) map.setLayoutProperty(layerId, 'visibility', 'none');
        }
      }

      // adm3+ features (Wards, Sectors, etc.): render as subtle outlines visible when zoomed in
      const wardFeatures = allBoundaryFeatures.filter(
        (f: any) => f.properties?.feature_type === 'ward',
      );
      const wardCollection = { type: 'FeatureCollection', features: wardFeatures };
      if (map.getSource('ward-overlay')) {
        (map.getSource('ward-overlay') as maplibregl.GeoJSONSource).setData(wardCollection as any);
      } else if (wardFeatures.length > 0) {
        map.addSource('ward-overlay', { type: 'geojson', data: wardCollection as any });
        map.addLayer({
          id: 'ward-outline',
          type: 'line',
          source: 'ward-overlay',
          minzoom: 8,
          paint: {
            'line-color': '#64748b',
            'line-width': 0.75,
            'line-opacity': 0.6,
          },
        } as any);
      }

      // Highlight overlay — separate source so we can show any single feature
      if (!map.getSource('highlight-overlay')) {
        map.addSource('highlight-overlay', { type: 'geojson', data: EMPTY_FC as any });
        map.addLayer({
          id: 'highlight-fill',
          type: 'fill',
          source: 'highlight-overlay',
          paint: { 'fill-color': '#3b82f6', 'fill-opacity': 0.55 },
        } as any);
      }
    } catch { /* silently skip if geojson unavailable */ }
  }

  async function loadHierarchy(): Promise<void> {
    const PROXY = normalizeBaseUrl(DEFAULT_PROXY_URL);
    try {
      const res = await fetch(`${PROXY}/boundaries/hierarchy?t=${selectedTenantId.value}&_=${Date.now()}`, {
        headers: { 'X-Tenant-ID': selectedTenantId.value },
      });
      boundaryHierarchy.value = res.ok ? await res.json() : null;
    } catch {
      boundaryHierarchy.value = null;
    }
  }

  async function reloadTenant(): Promise<void> {
    const tenant = currentTenant.value;
    allBoundaryFeatures = [];
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

    map.on('moveend', () => {
      refreshBoundarySummary();
    });

    map.once('load', () => {
      initMapInteractions();
      loadZoneOverlay();
    });

    map.on('idle', () => {
      currentZoom.value = map!.getZoom();
      if (!dataControls.value.length) {
        initControls();
      }
      updateControlStates();
      refreshBoundarySummary();
    });

    await loadHierarchy();
  }

  function flyToHierarchyItem(state: HierarchyState, lga?: HierarchyLGA): void {
    if (!map) return;
    if (lga && lga.center_lon != null && lga.center_lat != null) {
      const lngLat: [number, number] = [lga.center_lon, lga.center_lat];
      map.once('moveend', () => {
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '220px' })
          .setLngLat(lngLat)
          .setHTML(
            `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">LGA</div>` +
            `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${lga.name}</div>` +
            `<div style="font-size:11px;color:#475569;margin-top:3px">${state.name}</div>`
          )
          .addTo(map!);
      });
      map.flyTo({ center: lngLat, zoom: Math.max(map.getZoom(), 9), duration: 600 });
    } else if (state.center_lon != null && state.center_lat != null) {
      const lngLat: [number, number] = [state.center_lon, state.center_lat];
      map.once('moveend', () => {
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '220px' })
          .setLngLat(lngLat)
          .setHTML(
            `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">State</div>` +
            `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${state.name}</div>`
          )
          .addTo(map!);
      });
      map.flyTo({ center: lngLat, zoom: Math.max(map.getZoom(), 7), duration: 600 });
    }
  }

  function cleanup(): void {
    if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
    if (map) {
      map.remove();
      map = null;
    }
  }

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
    currentTenant,
    currentZoom,
    dataControls,
    boundarySummary,
    boundarySearch,
    boundaryHierarchy,
    mapContainer,

    baseControls,
    boundaryControls,
    filteredStateNames,
    filteredLGANames,
    filteredHierarchy,

    reloadTenant,
    toggleControl,
    refreshBoundarySummary,
    zoomToName,
    flyToHierarchyItem,
    highlightBoundary,
    highlight,
    loadHierarchy,
    cleanup,
  };
}
