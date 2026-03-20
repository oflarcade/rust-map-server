import { computed, reactive, ref, watch } from 'vue';
import maplibregl from 'maplibre-gl';
import { useQuery } from '@tanstack/vue-query';
import { fetchBoundaryGeoJSON } from '../api/boundaries';
import { useTileInspector } from './useTileInspector';
import type { DataControlRow } from '../types/map';
import type { BoundarySummary } from '../types/boundary';
import type { BoundaryFeature } from '../types/geojson';

// Module-level shared state — pre-populated so the Layers panel always has rows
const dataControls = ref<DataControlRow[]>([
  { id: 'water',      group: 'base', label: 'Water',      layers: ['base-water'],        countryLayerPrefixes: ['co-water-'],  visible: true },
  { id: 'landcover',  group: 'base', label: 'Landcover',  layers: ['base-landcover'],    countryLayerPrefixes: ['co-lc-'],     visible: true },
  { id: 'landuse',    group: 'base', label: 'Landuse',    layers: ['base-landuse'],                                            visible: true },
  { id: 'roads',      group: 'base', label: 'Roads',      layers: ['base-roads'],        countryLayerPrefixes: ['co-road-'],   visible: true },
  { id: 'roads-major',group: 'base', label: 'Major roads',layers: ['base-roads-major'],  countryLayerPrefixes: ['co-road-'],   visible: true },
  { id: 'buildings',  group: 'base', label: 'Buildings',  layers: ['base-buildings'],                                          visible: true },
  { id: 'places',     group: 'base', label: 'Places',     layers: ['base-place-label'],  countryLayerPrefixes: ['co-place-'],  visible: true },
  { id: 'zones',             group: 'boundary', label: 'Administrative areas', layers: ['zones-fill', 'zones-outline'],  countryLayerPrefixes: ['co-fill-', 'co-outline-'],      visible: true },
  { id: 'boundary-fill',     group: 'boundary', label: 'Boundary areas',       layers: ['boundary-fill'],                countryLayerPrefixes: ['co-hdx-state-fill'],            visible: true },
  { id: 'boundary-state',    group: 'boundary', label: 'State lines',          layers: ['boundary-state-line'],          countryLayerPrefixes: ['co-hdx-state-line'],            visible: true },
  { id: 'boundary-lga',      group: 'boundary', label: 'LGA lines',            layers: ['boundary-lga-line'],            countryLayerPrefixes: ['co-hdx-lga-line'],              visible: true },
  { id: 'boundary-ward',     group: 'boundary', label: 'Ward/Sector lines',    layers: ['ward-outline'],                                                                         visible: true },
  { id: 'boundary-state-label', group: 'boundary', label: 'State labels',      layers: ['boundary-state-label'],         countryLayerPrefixes: ['co-hdx-state-label'],           visible: true },
  { id: 'boundary-lga-label',   group: 'boundary', label: 'LGA labels',        layers: ['boundary-lga-label'],                                                                   visible: true },
]);

const boundarySummary = reactive<BoundarySummary>({
  states: 0,
  lgas: 0,
  stateNames: [],
  lgaNames: [],
  clickedLGA: '',
});

let allBoundaryFeatures: BoundaryFeature[] = [];

const EMPTY_FC: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };

export function useMapLayers() {
  const { selectedTenantId, getMap } = useTileInspector();

  const { data: geoJSONData } = useQuery({
    queryKey: computed(() => ['tenant', selectedTenantId.value, 'geojson']),
    queryFn: () => fetchBoundaryGeoJSON(selectedTenantId.value),
  });

  // Watch query data → call loadZoneOverlay logic
  watch(geoJSONData, (geojson) => {
    if (!geojson) return;
    loadZoneOverlay(geojson);
  });

  // -- Layer control helpers ------------------------------------------------

  function updateControlStates() {
    const map = getMap();
    if (!map || !map.getStyle()) {
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
      { id: 'water',      group: 'base', label: 'Water',      layers: ['base-water'],        countryLayerPrefixes: ['co-water-'],  visible: true },
      { id: 'landcover',  group: 'base', label: 'Landcover',  layers: ['base-landcover'],    countryLayerPrefixes: ['co-lc-'],     visible: true },
      { id: 'landuse',    group: 'base', label: 'Landuse',    layers: ['base-landuse'],                                            visible: true },
      { id: 'roads',      group: 'base', label: 'Roads',      layers: ['base-roads'],        countryLayerPrefixes: ['co-road-'],   visible: true },
      { id: 'roads-major',group: 'base', label: 'Major roads',layers: ['base-roads-major'],  countryLayerPrefixes: ['co-road-'],   visible: true },
      { id: 'buildings',  group: 'base', label: 'Buildings',  layers: ['base-buildings'],                                          visible: true },
      { id: 'places',     group: 'base', label: 'Places',     layers: ['base-place-label'],  countryLayerPrefixes: ['co-place-'],  visible: true },
      { id: 'zones',      group: 'boundary', label: 'Administrative areas', layers: ['zones-fill', 'zones-outline'], countryLayerPrefixes: ['co-fill-', 'co-outline-'], visible: true },
      { id: 'boundary-fill',         group: 'boundary', label: 'Boundary areas',   layers: ['boundary-fill'],         countryLayerPrefixes: ['co-hdx-state-fill'],  visible: true },
      { id: 'boundary-state',        group: 'boundary', label: 'State lines',      layers: ['boundary-state-line'],   countryLayerPrefixes: ['co-hdx-state-line'],  visible: true },
      { id: 'boundary-lga',          group: 'boundary', label: 'LGA lines',        layers: ['boundary-lga-line'],     countryLayerPrefixes: ['co-hdx-lga-line'],    visible: true },
      { id: 'boundary-ward',         group: 'boundary', label: 'Ward/Sector lines',layers: ['ward-outline'],                                                         visible: true },
      { id: 'boundary-state-label',  group: 'boundary', label: 'State labels',     layers: ['boundary-state-label'],  countryLayerPrefixes: ['co-hdx-state-label'], visible: true },
      { id: 'boundary-lga-label',    group: 'boundary', label: 'LGA labels',       layers: ['boundary-lga-label'],                                                   visible: true },
    ];
  }

  function refreshBoundarySummary(): void {
    boundarySummary.states = 0;
    boundarySummary.lgas = 0;
    boundarySummary.stateNames = [];
    boundarySummary.lgaNames = [];

    const map = getMap();
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

  function toggleControl(row: DataControlRow): void {
    const map = getMap();
    if (!map) return;
    const nextVisible = !row.visible;
    const vis = nextVisible ? 'visible' : 'none';
    // Toggle normal mode layers
    for (const layerId of row.layers) {
      if (map.getLayer(layerId)) map.setLayoutProperty(layerId, 'visibility', vis);
    }
    // Toggle country-mode equivalent layers (prefix match)
    if (row.countryLayerPrefixes?.length) {
      for (const layer of map.getStyle().layers ?? []) {
        if (row.countryLayerPrefixes.some((p) => layer.id.startsWith(p) || layer.id === p)) {
          if (map.getLayer(layer.id)) map.setLayoutProperty(layer.id, 'visibility', vis);
        }
      }
    }
    updateControlStates();
    refreshBoundarySummary();
  }

  function loadZoneOverlay(geojson: GeoJSON.FeatureCollection): void {
    const map = getMap();
    if (!map) return;

    // Store all features for highlight lookups (state, lga, zone all have pcode)
    allBoundaryFeatures = (geojson.features ?? []) as BoundaryFeature[];

    const zoneFeatures = allBoundaryFeatures.filter(
      (f) => f.properties?.feature_type === 'zone',
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
      (f) => f.properties?.feature_type === 'ward',
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
  }

  // -- Computed -------------------------------------------------------------

  const baseControls = computed(() =>
    dataControls.value.filter((row) => row.group === 'base'),
  );

  const boundaryControls = computed(() =>
    dataControls.value.filter((row) => row.group === 'boundary'),
  );

  function getAllBoundaryFeatures(): BoundaryFeature[] {
    return allBoundaryFeatures;
  }

  return {
    dataControls,
    boundarySummary,
    baseControls,
    boundaryControls,
    toggleControl,
    refreshBoundarySummary,
    initControls,
    updateControlStates,
    getAllBoundaryFeatures,
  };
}
