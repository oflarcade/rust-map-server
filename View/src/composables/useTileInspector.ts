import { computed, reactive, ref, watch } from 'vue';
import maplibregl, { type Map } from 'maplibre-gl';
import { DEFAULT_MARTIN_URL, normalizeBaseUrl } from '../config/urls';
import { TENANTS, type TenantConfig, HIERARCHY_MAP } from '../config/tenants';

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
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
}

export interface HierarchyState {
  pcode: string;
  name: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
  lgas: HierarchyLGA[];
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
const baseMeta = reactive<Record<string, any>>({});
const boundaryMeta = reactive<Record<string, any>>({});

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

  async function fetchJson<T = any>(url: string): Promise<T> {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${res.status} ${url}`);
    return (await res.json()) as T;
  }

  function resetMeta(target: Record<string, any>) {
    Object.keys(target).forEach((k) => delete target[k]);
  }

  function getSourceLayer(meta: any, preferred: string): string {
    const layers = Array.isArray(meta.vector_layers) ? meta.vector_layers : [];
    const found = layers.find((l: any) => l && l.id === preferred);
    return found ? found.id : '';
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

  function buildStyle(
    base: any,
    boundary: any,
    baseUrl: string,
    boundaryUrl: string,
  ): maplibregl.StyleSpecification {
    const styleLayers: maplibregl.LayerSpecification[] = [];
    const present = (name: string) => getSourceLayer(base, name);

    styleLayers.push({
      id: 'background',
      type: 'background',
      paint: { 'background-color': '#f5f3ee' },
    });

    if (present('water')) {
      styleLayers.push({
        id: 'base-water',
        type: 'fill',
        source: 'base',
        'source-layer': 'water',
        paint: { 'fill-color': '#a0cfdf' },
      } as any);
    }

    if (present('landcover')) {
      styleLayers.push({
        id: 'base-landcover',
        type: 'fill',
        source: 'base',
        'source-layer': 'landcover',
        paint: { 'fill-color': '#d6ead1', 'fill-opacity': 0.55 },
      } as any);
    }

    if (present('landuse')) {
      styleLayers.push({
        id: 'base-landuse',
        type: 'fill',
        source: 'base',
        'source-layer': 'landuse',
        paint: { 'fill-color': '#ece9d8', 'fill-opacity': 0.45 },
      } as any);
    }

    if (present('transportation')) {
      styleLayers.push({
        id: 'base-roads',
        type: 'line',
        source: 'base',
        'source-layer': 'transportation',
        paint: { 'line-color': '#888', 'line-width': 1 },
      } as any);
      styleLayers.push({
        id: 'base-roads-major',
        type: 'line',
        source: 'base',
        'source-layer': 'transportation',
        filter: ['in', 'class', 'primary', 'secondary', 'trunk', 'motorway'],
        paint: { 'line-color': '#f59e0b', 'line-width': 2 },
      } as any);
    }

    if (present('building')) {
      styleLayers.push({
        id: 'base-buildings',
        type: 'fill',
        source: 'base',
        'source-layer': 'building',
        minzoom: 12,
        paint: { 'fill-color': '#d7c6a7', 'fill-opacity': 0.65 },
      } as any);
    }

    if (present('place')) {
      styleLayers.push({
        id: 'base-place-label',
        type: 'symbol',
        source: 'base',
        'source-layer': 'place',
        layout: {
          'text-field': ['coalesce', ['get', 'name:latin'], ['get', 'name']],
          'text-size': 11,
        },
        paint: {
          'text-color': '#2c2c2c',
          'text-halo-color': '#fff',
          'text-halo-width': 1.2,
        },
      } as any);
    }

    // -- Boundary layers (HDX property-based filters) -----------------------

    const boundaryLayer =
      getSourceLayer(boundary, 'boundaries') ||
      (Array.isArray(boundary.vector_layers) &&
        boundary.vector_layers[0]?.id) ||
      '';

    if (boundaryLayer) {
      const lgaFilter: any = ['has', 'adm2_name'];
      const stateFilter: any = ['!', ['has', 'adm2_name']];

      styleLayers.push({
        id: 'boundary-fill',
        type: 'fill',
        source: 'boundary',
        'source-layer': boundaryLayer,
        filter: lgaFilter,
        paint: { 'fill-color': '#60a5fa', 'fill-opacity': 0.15 },
      } as any);

      styleLayers.push({
        id: 'boundary-state-line',
        type: 'line',
        source: 'boundary',
        'source-layer': boundaryLayer,
        filter: stateFilter,
        paint: { 'line-color': '#2563eb', 'line-width': 2 },
      } as any);

      styleLayers.push({
        id: 'boundary-lga-line',
        type: 'line',
        source: 'boundary',
        'source-layer': boundaryLayer,
        filter: lgaFilter,
        paint: { 'line-color': '#6366f1', 'line-width': 1 },
      } as any);

      styleLayers.push({
        id: 'boundary-state-label',
        type: 'symbol',
        source: 'boundary',
        'source-layer': boundaryLayer,
        filter: stateFilter,
        layout: {
          'text-field': ['coalesce', ['get', 'adm1_name'], ['get', 'name']],
          'text-size': 13,
          'text-max-width': 8,
          'text-allow-overlap': false,
        },
        paint: {
          'text-color': '#1e3a5f',
          'text-halo-color': '#fff',
          'text-halo-width': 1.5,
        },
      } as any);

      styleLayers.push({
        id: 'boundary-lga-label',
        type: 'symbol',
        source: 'boundary',
        'source-layer': boundaryLayer,
        minzoom: 8,
        filter: lgaFilter,
        layout: {
          'text-field': ['coalesce', ['get', 'adm2_name'], ['get', 'name']],
          'text-size': 10,
          'text-max-width': 6,
          'text-allow-overlap': false,
        },
        paint: {
          'text-color': '#0f172a',
          'text-halo-color': '#fff',
          'text-halo-width': 1,
        },
      } as any);
    }

    return {
      version: 8,
      glyphs: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',
      sources: {
        base: {
          type: 'vector',
          tiles: [baseUrl],
          minzoom: base.minzoom ?? 0,
          maxzoom: base.maxzoom ?? 14,
        },
        boundary: {
          type: 'vector',
          tiles: [boundaryUrl],
          minzoom: boundary.minzoom ?? 0,
          maxzoom: boundary.maxzoom ?? 14,
        },
      },
      layers: styleLayers,
    } as maplibregl.StyleSpecification;
  }

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
      const name = props.adm2_name || props.name || '';

      if (feature.geometry) {
        const bounds = bboxFromGeometry(feature.geometry as GeoJSON.Geometry);
        map?.fitBounds(bounds, { padding: 60, maxZoom: 14 });
      }
      if (name) {
        boundarySummary.clickedLGA = String(name);
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
      { id: 'boundary-fill', group: 'boundary', label: 'Boundary areas', layers: ['boundary-fill'], visible: true },
      { id: 'boundary-state', group: 'boundary', label: 'State lines', layers: ['boundary-state-line'], visible: true },
      { id: 'boundary-lga', group: 'boundary', label: 'LGA lines', layers: ['boundary-lga-line'], visible: true },
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

  function highlightBoundary(name: string | null): void {
    if (!map) return;

    if (!name) {
      if (map.getLayer('boundary-fill')) {
        map.setPaintProperty('boundary-fill', 'fill-opacity', 0.15);
        map.setPaintProperty('boundary-fill', 'fill-color', '#60a5fa');
      }
      if (map.getLayer('boundary-state-line')) {
        map.setPaintProperty('boundary-state-line', 'line-opacity', 1);
        map.setPaintProperty('boundary-state-line', 'line-color', '#2563eb');
      }
      if (map.getLayer('boundary-lga-line')) {
        map.setPaintProperty('boundary-lga-line', 'line-opacity', 1);
        map.setPaintProperty('boundary-lga-line', 'line-color', '#6366f1');
      }
      if (map.getLayer('boundary-state-label')) {
        map.setPaintProperty('boundary-state-label', 'text-opacity', 1);
      }
      if (map.getLayer('boundary-lga-label')) {
        map.setPaintProperty('boundary-lga-label', 'text-opacity', 1);
      }
      return;
    }

    const matchByState: any = ['==', ['get', 'adm1_name'], name];
    const matchByLga: any = ['==', ['get', 'adm2_name'], name];
    const matchAny: any = ['any', matchByState, matchByLga, ['==', ['get', 'name'], name]];

    if (map.getLayer('boundary-fill')) {
      map.setPaintProperty('boundary-fill', 'fill-opacity', [
        'case', matchAny, 0.5, 0.06,
      ]);
      map.setPaintProperty('boundary-fill', 'fill-color', [
        'case', matchAny, '#3b82f6', '#94a3b8',
      ]);
    }
    if (map.getLayer('boundary-state-line')) {
      map.setPaintProperty('boundary-state-line', 'line-opacity', 1);
      map.setPaintProperty('boundary-state-line', 'line-color', '#2563eb');
    }
    if (map.getLayer('boundary-lga-line')) {
      map.setPaintProperty('boundary-lga-line', 'line-opacity', [
        'case', matchAny, 1, 0.08,
      ]);
      map.setPaintProperty('boundary-lga-line', 'line-color', [
        'case', matchAny, '#6366f1', '#64748b',
      ]);
    }
    if (map.getLayer('boundary-state-label')) {
      map.setPaintProperty('boundary-state-label', 'text-opacity', [
        'case', matchByState, 1, 0.15,
      ]);
    }
    if (map.getLayer('boundary-lga-label')) {
      map.setPaintProperty('boundary-lga-label', 'text-opacity', [
        'case', matchAny, 1, 0.15,
      ]);
    }
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

  async function loadHierarchy(): Promise<void> {
    const slug = HIERARCHY_MAP[selectedTenantId.value];
    if (!slug) {
      boundaryHierarchy.value = null;
      return;
    }
    try {
      boundaryHierarchy.value = await fetchJson<HierarchyData>(
        `/hdx/${slug}-hierarchy.json`,
      );
    } catch {
      boundaryHierarchy.value = null;
    }
  }

  async function reloadTenant(): Promise<void> {
    const tenant = currentTenant.value;
    const base = normalizeBaseUrl(DEFAULT_MARTIN_URL);

    resetMeta(baseMeta);
    resetMeta(boundaryMeta);

    Object.assign(baseMeta, await fetchJson<any>(`${base}/${tenant.source}`).catch(() => ({})));

    const boundarySourceKey = tenant.hdxBoundarySource ?? tenant.boundarySource;
    try {
      Object.assign(boundaryMeta, await fetchJson<any>(`${base}/${boundarySourceKey}`));
    } catch {
      Object.assign(boundaryMeta, { vector_layers: [], bounds: null });
    }

    const baseTileUrl = `${base}/${tenant.source}/{z}/{x}/{y}`;
    const boundaryTileUrl = `${base}/${boundarySourceKey}/{z}/{x}/{y}`;
    const style = buildStyle(baseMeta, boundaryMeta, baseTileUrl, boundaryTileUrl);

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

  function cleanup(): void {
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
    highlightBoundary,
    highlight,
    loadHierarchy,
    cleanup,
  };
}
