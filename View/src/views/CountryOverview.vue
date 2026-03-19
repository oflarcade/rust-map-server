<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import maplibregl from 'maplibre-gl';
import { TENANTS } from '../config/tenants';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';

const route  = useRoute();
const router = useRouter();
const BASE   = normalizeBaseUrl(DEFAULT_PROXY_URL);

const mapContainer = ref<HTMLDivElement | null>(null);
const loadStatus   = ref('');
const visibleTenants = ref<Set<string>>(new Set());

// The country code from the route (/country/:countryCode)
const countryCode = computed(() => (route.params.countryCode as string ?? '').toUpperCase());

// All tenants for this country
const countryTenants = computed(() =>
  TENANTS.filter(t => t.countryCode === countryCode.value)
);

// 10-colour cycling palette for tenants
const PALETTE = [
  '#3b82f6', '#ef4444', '#10b981', '#f59e0b', '#8b5cf6',
  '#ec4899', '#06b6d4', '#84cc16', '#f97316', '#6366f1',
];

const tenantColors = computed(() => {
  const map: Record<string, string> = {};
  countryTenants.value.forEach((t, i) => {
    map[t.id] = PALETTE[i % PALETTE.length];
  });
  return map;
});

let map: maplibregl.Map | null = null;
let popup: maplibregl.Popup | null = null;

function toggleTenant(id: string) {
  const next = new Set(visibleTenants.value);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  visibleTenants.value = next;
  applyLayerVisibility();
}

function applyLayerVisibility() {
  if (!map) return;
  for (const t of countryTenants.value) {
    const vis = visibleTenants.value.has(t.id) ? 'visible' : 'none';
    if (map.getLayer(`co-fill-${t.id}`))    map.setLayoutProperty(`co-fill-${t.id}`, 'visibility', vis);
    if (map.getLayer(`co-outline-${t.id}`)) map.setLayoutProperty(`co-outline-${t.id}`, 'visibility', vis);
  }
}

async function initMap() {
  if (map) { map.remove(); map = null; }
  if (!mapContainer.value || countryTenants.value.length === 0) return;

  // Default center from first tenant
  const first = countryTenants.value[0];
  loadStatus.value = 'Loading map…';

  map = new maplibregl.Map({
    container: mapContainer.value,
    style: {
      version: 8,
      sources: { 'osm-raster': { type: 'raster', tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'], tileSize: 256, attribution: '© OpenStreetMap contributors' } },
      layers:  [{ id: 'osm-raster', type: 'raster', source: 'osm-raster' }],
    },
    center: [first.lon, first.lat],
    zoom: first.zoom,
  });
  map.addControl(new maplibregl.NavigationControl());

  // Mark all tenants visible initially
  visibleTenants.value = new Set(countryTenants.value.map(t => t.id));

  map.on('load', async () => {
    loadStatus.value = 'Loading boundary data…';

    // Fetch GeoJSON for all tenants in parallel
    const results = await Promise.allSettled(
      countryTenants.value.map(async (t) => {
        const res = await fetch(`${BASE}/boundaries/geojson?t=${t.id}`, {
          headers: { 'X-Tenant-ID': t.id },
        });
        if (!res.ok) throw new Error(`Tenant ${t.id}: ${res.status}`);
        const data = await res.json();
        return { tenantId: t.id, features: data.features ?? [] };
      })
    );

    const bounds = new maplibregl.LngLatBounds();

    for (const result of results) {
      if (result.status !== 'fulfilled') continue;
      const { tenantId, features } = result.value;
      const tenant = countryTenants.value.find(t => t.id === tenantId)!;
      const color  = tenantColors.value[tenantId];

      // Tag each feature with tenantId + tenantName for popup
      const tagged = features.map((f: any) => ({
        ...f,
        properties: { ...f.properties, _tenantId: tenantId, _tenantName: tenant.name },
      }));

      // Extend bounds
      for (const f of tagged) {
        if (f.geometry?.coordinates) {
          const coords = f.geometry.type === 'MultiPolygon' ? f.geometry.coordinates.flat(2) : f.geometry.coordinates.flat(1);
          coords.forEach((c: number[]) => { try { bounds.extend(c as [number, number]); } catch {} });
        }
      }

      map!.addSource(`co-src-${tenantId}`, { type: 'geojson', data: { type: 'FeatureCollection', features: tagged } });
      map!.addLayer({
        id: `co-fill-${tenantId}`,
        type: 'fill',
        source: `co-src-${tenantId}`,
        paint: { 'fill-color': color, 'fill-opacity': 0.22 },
      });
      map!.addLayer({
        id: `co-outline-${tenantId}`,
        type: 'line',
        source: `co-src-${tenantId}`,
        paint: { 'line-color': color, 'line-width': 1.5 },
      });

      // Click popup
      map!.on('click', `co-fill-${tenantId}`, (e) => {
        const feat = e.features?.[0];
        if (!feat) return;
        const p = feat.properties ?? {};
        if (popup) { popup.remove(); popup = null; }
        popup = new maplibregl.Popup({ maxWidth: '260px' })
          .setLngLat(e.lngLat)
          .setHTML(
            `<div style="font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:0.06em;margin-bottom:4px">${p._tenantName}</div>` +
            `<div style="font-size:13px;font-weight:600;color:#0f172a">${p.name ?? p.zone_name ?? p.pcode ?? ''}</div>` +
            `<div style="font-size:11px;color:#475569;margin-top:2px">${p.feature_type ?? ''} · ${p.pcode ?? p.zone_pcode ?? ''}</div>`
          )
          .addTo(map!);
      });
      map!.on('mouseenter', `co-fill-${tenantId}`, () => { map!.getCanvas().style.cursor = 'pointer'; });
      map!.on('mouseleave', `co-fill-${tenantId}`, () => { map!.getCanvas().style.cursor = ''; });
    }

    if (!bounds.isEmpty()) map!.fitBounds(bounds, { padding: 40, duration: 800 });
    loadStatus.value = '';
  });
}

watch(countryCode, () => initMap());
onMounted(() => initMap());
onUnmounted(() => { popup?.remove(); popup = null; map?.remove(); map = null; });
</script>

<template>
  <div class="co-root">
    <!-- Sidebar -->
    <aside class="co-sidebar">
      <div class="co-header">
        <button class="co-back" @click="router.push('/inspector')">← Inspector</button>
        <h2 class="co-title">{{ countryCode }} — All Tenants</h2>
      </div>

      <div v-if="countryTenants.length === 0" class="co-empty">
        No tenants found for country code "{{ countryCode }}".
      </div>

      <div v-else class="co-tenant-list">
        <div
          v-for="t in countryTenants" :key="t.id"
          class="co-tenant-row"
          :class="{ dimmed: !visibleTenants.has(t.id) }"
          @click="toggleTenant(t.id)"
        >
          <span class="co-swatch" :style="{ background: tenantColors[t.id] }"></span>
          <span class="co-tenant-name">{{ t.name }}</span>
          <span class="co-tenant-id">{{ t.id }}</span>
          <span class="co-vis-icon">{{ visibleTenants.has(t.id) ? '●' : '○' }}</span>
        </div>
      </div>

      <div v-if="loadStatus" class="co-status">{{ loadStatus }}</div>

      <div class="co-hint">Click a tenant row to show/hide its layer. Click the map for feature details.</div>
    </aside>

    <!-- Map -->
    <div ref="mapContainer" class="co-map" />
  </div>
</template>

<style scoped>
.co-root { display: grid; grid-template-columns: 300px 1fr; height: 100vh; font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }

.co-sidebar {
  background: #f8fafc;
  border-right: 1px solid #e2e8f0;
  padding: 16px;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.co-header { display: flex; flex-direction: column; gap: 6px; }
.co-back { background: #eff6ff; color: #1d4ed8; border: 1px solid #bfdbfe; border-radius: 6px; padding: 4px 10px; font-size: 12px; cursor: pointer; width: fit-content; }
.co-back:hover { background: #dbeafe; }
.co-title { font-size: 1rem; font-weight: 700; color: #0f172a; margin: 0; }

.co-empty { font-size: 13px; color: #94a3b8; font-style: italic; }

.co-tenant-list { display: flex; flex-direction: column; gap: 4px; }
.co-tenant-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border-radius: 8px;
  cursor: pointer;
  background: #ffffff;
  border: 1px solid #e2e8f0;
  transition: background 0.1s;
}
.co-tenant-row:hover { background: #f1f5f9; }
.co-tenant-row.dimmed { opacity: 0.4; }
.co-swatch { width: 12px; height: 12px; border-radius: 3px; flex-shrink: 0; }
.co-tenant-name { flex: 1; font-size: 13px; font-weight: 500; color: #1e293b; }
.co-tenant-id { font-size: 11px; color: #94a3b8; }
.co-vis-icon { font-size: 14px; color: #94a3b8; }

.co-status { font-size: 12px; color: #64748b; font-style: italic; }
.co-hint   { font-size: 11px; color: #94a3b8; line-height: 1.5; }

.co-map { width: 100%; height: 100%; }

@media (max-width: 700px) {
  .co-root { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
}
</style>
