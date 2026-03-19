import { ref, computed } from 'vue';
import maplibregl from 'maplibre-gl';
import { DEFAULT_PROXY_URL, DEFAULT_MARTIN_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from './useTileInspector';
import type { TenantConfig } from '../config/tenants';

const PALETTE = [
  '#3b82f6', '#ef4444', '#10b981', '#f59e0b', '#8b5cf6',
  '#ec4899', '#06b6d4', '#84cc16', '#f97316', '#6366f1',
];

const isCountryMode = ref(false);
const visibleCountryTenants = ref<Set<string>>(new Set());

let savedLayerVisibility = new Map<string, string>();
let addedLayerIds: string[] = [];
let addedSourceIds: string[] = [];
let countryPopup: maplibregl.Popup | null = null;

export function useCountryMode() {
  const { currentTenant, tenantList, getMap } = useTileInspector();
  const BASE   = normalizeBaseUrl(DEFAULT_PROXY_URL);
  const MARTIN = normalizeBaseUrl(DEFAULT_MARTIN_URL);

  const countryTenants = computed<TenantConfig[]>(() =>
    tenantList.value.filter((t) => t.countryCode === currentTenant.value.countryCode),
  );

  const tenantColors = computed<Record<string, string>>(() => {
    const m: Record<string, string> = {};
    countryTenants.value.forEach((t, i) => { m[t.id] = PALETTE[i % PALETTE.length]; });
    return m;
  });

  // ── helpers ──────────────────────────────────────────────────────────────

  function _addSource(map: maplibregl.Map, id: string, spec: maplibregl.SourceSpecification) {
    if (!map.getSource(id)) { map.addSource(id, spec); addedSourceIds.push(id); }
  }

  function _addLayer(map: maplibregl.Map, spec: maplibregl.LayerSpecification) {
    if (!map.getLayer(spec.id)) { map.addLayer(spec as any); addedLayerIds.push(spec.id); }
  }

  function toggleCountryTenant(id: string) {
    const map = getMap();
    if (!map) return;
    const next = new Set(visibleCountryTenants.value);
    if (next.has(id)) next.delete(id); else next.add(id);
    visibleCountryTenants.value = next;
    for (const t of countryTenants.value) {
      const vis = visibleCountryTenants.value.has(t.id) ? 'visible' : 'none';
      if (map.getLayer(`co-fill-${t.id}`))    map.setLayoutProperty(`co-fill-${t.id}`,    'visibility', vis);
      if (map.getLayer(`co-outline-${t.id}`)) map.setLayoutProperty(`co-outline-${t.id}`, 'visibility', vis);
    }
  }

  // ── main load ─────────────────────────────────────────────────────────────

  async function loadCountryOverlays(): Promise<void> {
    const map = getMap();
    if (!map) return;

    if (!map.isStyleLoaded()) {
      await new Promise<void>((resolve) => map.once('idle', resolve));
    }

    // 1. Save and hide all current layers
    savedLayerVisibility = new Map();
    for (const layer of map.getStyle().layers ?? []) {
      const vis = (map.getLayoutProperty(layer.id, 'visibility') as string) ?? 'visible';
      savedLayerVisibility.set(layer.id, vis);
      map.setLayoutProperty(layer.id, 'visibility', 'none');
    }

    // 2. Solid background
    _addLayer(map, { id: 'co-bg', type: 'background', paint: { 'background-color': '#e8e4d9' } } as any);

    // 3. All country-tenant Martin tile sources (vector, direct to Martin port)
    //    Each covers only its area; together they fill the full operated country.
    const metaResults = await Promise.allSettled(
      countryTenants.value.map(async (t) => {
        const meta = await fetch(`${MARTIN}/${t.source}`).then((r) => r.json()).catch(() => ({}));
        return { tenant: t, meta };
      }),
    );

    for (const r of metaResults) {
      if (r.status !== 'fulfilled') continue;
      const { tenant: t, meta } = r.value;
      const srcId = `co-base-${t.id}`;
      _addSource(map, srcId, {
        type: 'vector',
        tiles: [`${MARTIN}/${t.source}/{z}/{x}/{y}`],
        minzoom: meta.minzoom ?? 0,
        maxzoom: meta.maxzoom ?? 14,
      });
      const vl: string[] = (meta.vector_layers ?? []).map((l: any) => l.id as string);
      if (vl.includes('water'))          _addLayer(map, { id: `co-water-${t.id}`,  type: 'fill',   source: srcId, 'source-layer': 'water',          paint: { 'fill-color': '#a0cfdf' } } as any);
      if (vl.includes('landcover'))      _addLayer(map, { id: `co-lc-${t.id}`,     type: 'fill',   source: srcId, 'source-layer': 'landcover',       paint: { 'fill-color': '#d6ead1', 'fill-opacity': 0.6 } } as any);
      if (vl.includes('transportation')) _addLayer(map, { id: `co-road-${t.id}`,   type: 'line',   source: srcId, 'source-layer': 'transportation',  minzoom: 7, paint: { 'line-color': '#bbb', 'line-width': 0.6 } } as any);
      if (vl.includes('place'))          _addLayer(map, { id: `co-place-${t.id}`,  type: 'symbol', source: srcId, 'source-layer': 'place', minzoom: 7,
        layout: { 'text-field': ['coalesce', ['get', 'name:latin'], ['get', 'name']], 'text-size': 10 },
        paint: { 'text-color': '#333', 'text-halo-color': '#fff', 'text-halo-width': 1 } } as any);
    }

    // 4. HDX full-country boundary vector tiles (all states + all LGAs)
    const hdxSource = countryTenants.value.find((t) => t.hdxBoundarySource)?.hdxBoundarySource;
    let hdxVectorLayer = 'boundaries';
    if (hdxSource) {
      const hdxMeta = await fetch(`${MARTIN}/${hdxSource}`).then((r) => r.json()).catch(() => ({}));
      hdxVectorLayer = hdxMeta.vector_layers?.[0]?.id ?? 'boundaries';
      _addSource(map, 'co-hdx', {
        type: 'vector',
        tiles: [`${MARTIN}/${hdxSource}/{z}/{x}/{y}`],
        minzoom: hdxMeta.minzoom ?? 0,
        maxzoom: hdxMeta.maxzoom ?? 14,
      });
      // All state outlines
      _addLayer(map, {
        id: 'co-hdx-state-fill', type: 'fill', source: 'co-hdx', 'source-layer': hdxVectorLayer,
        filter: ['!', ['has', 'adm2_pcode']],
        paint: { 'fill-color': '#94a3b8', 'fill-opacity': 0.05 },
      } as any);
      _addLayer(map, {
        id: 'co-hdx-state-line', type: 'line', source: 'co-hdx', 'source-layer': hdxVectorLayer,
        filter: ['!', ['has', 'adm2_pcode']],
        paint: { 'line-color': '#475569', 'line-width': 1.8, 'line-opacity': 0.8 },
      } as any);
      // All LGA outlines
      _addLayer(map, {
        id: 'co-hdx-lga-line', type: 'line', source: 'co-hdx', 'source-layer': hdxVectorLayer,
        filter: ['has', 'adm2_pcode'], minzoom: 6,
        paint: { 'line-color': '#94a3b8', 'line-width': 0.5, 'line-opacity': 0.6 },
      } as any);
      // State name labels
      _addLayer(map, {
        id: 'co-hdx-state-label', type: 'symbol', source: 'co-hdx', 'source-layer': hdxVectorLayer,
        filter: ['!', ['has', 'adm2_pcode']],
        layout: { 'text-field': ['coalesce', ['get', 'adm1_name'], ['get', 'name']], 'text-size': 12, 'text-max-width': 8, 'text-allow-overlap': false },
        paint: { 'text-color': '#1e3a5f', 'text-halo-color': '#fff', 'text-halo-width': 1.5 },
      } as any);
    }

    // 5. Tenant GeoJSON fills (colored operated areas) + hover popups
    visibleCountryTenants.value = new Set(countryTenants.value.map((t) => t.id));
    const bounds = new maplibregl.LngLatBounds();

    const geoResults = await Promise.allSettled(
      countryTenants.value.map(async (t) => {
        const res = await fetch(`${BASE}/boundaries/geojson?t=${t.id}`, {
          headers: { 'X-Tenant-ID': t.id },
        });
        if (!res.ok) throw new Error(`${t.id}: ${res.status}`);
        const data = await res.json();
        return { tenantId: t.id, features: data.features ?? [] };
      }),
    );

    for (const result of geoResults) {
      if (result.status !== 'fulfilled') continue;
      const { tenantId, features } = result.value;
      const tenant = countryTenants.value.find((t) => t.id === tenantId)!;
      const color  = tenantColors.value[tenantId];

      const tagged = features.map((f: any) => ({
        ...f,
        properties: { ...f.properties, _tenantId: tenantId, _tenantName: tenant.name, _color: color },
      }));

      for (const f of tagged) {
        if (!f.geometry?.coordinates) continue;
        const raw = f.geometry.type === 'MultiPolygon' ? f.geometry.coordinates.flat(2) : f.geometry.coordinates.flat(1);
        raw.forEach((c: number[]) => { try { bounds.extend(c as [number, number]); } catch { /* skip */ } });
      }

      const srcId = `co-src-${tenantId}`;
      if (map.getSource(srcId)) {
        (map.getSource(srcId) as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: tagged });
      } else {
        _addSource(map, srcId, { type: 'geojson', data: { type: 'FeatureCollection', features: tagged } });
      }

      _addLayer(map, {
        id: `co-fill-${tenantId}`, type: 'fill', source: srcId,
        paint: { 'fill-color': color, 'fill-opacity': 0.28 },
      } as any);
      _addLayer(map, {
        id: `co-outline-${tenantId}`, type: 'line', source: srcId,
        paint: { 'line-color': color, 'line-width': 1.6 },
      } as any);

      // Hover popup showing tenant + feature name
      map.on('mouseenter', `co-fill-${tenantId}`, () => { map.getCanvas().style.cursor = 'pointer'; });
      map.on('mouseleave', `co-fill-${tenantId}`, () => {
        map.getCanvas().style.cursor = '';
        if (countryPopup) { countryPopup.remove(); countryPopup = null; }
      });
      map.on('mousemove', `co-fill-${tenantId}`, (e) => {
        const feat = e.features?.[0];
        if (!feat) return;
        const p = feat.properties ?? {} as any;
        if (countryPopup) countryPopup.remove();
        countryPopup = new maplibregl.Popup({ closeButton: false, closeOnClick: false, maxWidth: '220px', offset: 6 })
          .setLngLat(e.lngLat)
          .setHTML(
            `<div style="font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:0.06em;margin-bottom:3px">${p._tenantName ?? ''}</div>` +
            `<div style="font-size:13px;font-weight:600;color:#0f172a">${p.name ?? p.zone_name ?? p.pcode ?? ''}</div>` +
            `<div style="font-size:11px;color:#475569;margin-top:2px">${p.feature_type ?? ''}</div>`,
          )
          .addTo(map);
      });
    }

    if (!bounds.isEmpty()) map.fitBounds(bounds, { padding: 40, duration: 800 });
  }

  // ── clear ─────────────────────────────────────────────────────────────────

  function clearCountryOverlays(): void {
    const map = getMap();
    if (!map) return;

    if (countryPopup) { countryPopup.remove(); countryPopup = null; }

    // Remove in reverse order (layers before sources)
    for (const id of [...addedLayerIds].reverse()) {
      if (map.getLayer(id)) map.removeLayer(id);
    }
    for (const id of [...addedSourceIds].reverse()) {
      if (map.getSource(id)) map.removeSource(id);
    }
    addedLayerIds = [];
    addedSourceIds = [];

    // Restore previous layer visibility
    for (const [id, vis] of savedLayerVisibility) {
      if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', vis);
    }
    savedLayerVisibility = new Map();
    visibleCountryTenants.value = new Set();
  }

  return {
    isCountryMode,
    countryTenants,
    tenantColors,
    visibleCountryTenants,
    toggleCountryTenant,
    loadCountryOverlays,
    clearCountryOverlays,
  };
}
