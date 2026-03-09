<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted } from 'vue';
import maplibregl from 'maplibre-gl';
import { TENANTS, getTenantById, type TenantConfig } from '../config/tenants';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';

const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const selectedTenantId = ref(TENANTS[0]?.id ?? '11');
const adminToken       = ref('');
const mapContainer     = ref<HTMLDivElement | null>(null);
const statusMsg        = ref('');
const statusType       = ref<'info' | 'error' | 'success'>('info');

// Zone form
const zoneName     = ref('');
const zoneColor    = ref('#3b82f6');
const selectedLgas = ref<string[]>([]);   // pcodes of clicked LGAs
const existingZones = ref<Zone[]>([]);
const editingZone   = ref<Zone | null>(null);

interface Zone {
  zone_id: number;
  zone_pcode: string;
  zone_name: string;
  color: string;
  parent_pcode: string;
  constituent_pcodes: string[];
}

let map: maplibregl.Map | null = null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function setStatus(msg: string, type: 'info' | 'error' | 'success' = 'info') {
  statusMsg.value  = msg;
  statusType.value = type;
}

function tenantHeaders(extra: Record<string, string> = {}) {
  return {
    'X-Tenant-ID': selectedTenantId.value,
    ...extra,
  };
}

function adminHeaders(extra: Record<string, string> = {}) {
  return tenantHeaders({ 'X-Admin-Token': adminToken.value, ...extra });
}

// ---------------------------------------------------------------------------
// Load GeoJSON and zones from server
// ---------------------------------------------------------------------------
async function loadBoundaries() {
  if (!map) return;
  setStatus('Loading boundaries…');

  try {
    const [geojsonRes, zonesRes] = await Promise.all([
      fetch(`${BASE}/boundaries/geojson`, { headers: tenantHeaders() }),
      fetch(`${BASE}/admin/zones`,         { headers: tenantHeaders() }),
    ]);

    if (!geojsonRes.ok) throw new Error(`boundaries/geojson: ${geojsonRes.status}`);
    const geojson = await geojsonRes.json();

    if (zonesRes.ok) {
      const zonesData = await zonesRes.json();
      existingZones.value = zonesData.zones ?? [];
    }

    // Separate LGAs and zones from the FeatureCollection
    const lgaFeatures  = geojson.features.filter((f: any) => f.properties.feature_type === 'lga');
    const zoneFeatures = geojson.features.filter((f: any) => f.properties.feature_type === 'zone');

    // Update or add sources
    if (map.getSource('lgas')) {
      (map.getSource('lgas') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: lgaFeatures });
    }
    if (map.getSource('zones')) {
      (map.getSource('zones') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: zoneFeatures });
    }

    // Fit map to data bounds
    if (geojson.features.length > 0) {
      const bounds = new maplibregl.LngLatBounds();
      geojson.features.forEach((f: any) => {
        if (f.geometry?.coordinates) {
          const coords = f.geometry.type === 'MultiPolygon'
            ? f.geometry.coordinates.flat(2)
            : f.geometry.coordinates.flat(1);
          coords.forEach((c: number[]) => bounds.extend(c as [number, number]));
        }
      });
      if (!bounds.isEmpty()) {
        map.fitBounds(bounds, { padding: 40, duration: 800 });
      }
    }

    setStatus(`Loaded ${lgaFeatures.length} LGAs, ${existingZones.value.length} zones`, 'success');
  } catch (err: any) {
    setStatus(`Failed to load: ${err.message}`, 'error');
  }
}

// ---------------------------------------------------------------------------
// Map initialisation
// ---------------------------------------------------------------------------
function initMap(tenant: TenantConfig) {
  if (map) {
    map.remove();
    map = null;
  }

  map = new maplibregl.Map({
    container: mapContainer.value!,
    style: {
      version: 8,
      sources: {
        'osm-raster': {
          type: 'raster',
          tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
          tileSize: 256,
          attribution: '© OpenStreetMap contributors',
        },
      },
      layers: [{ id: 'osm-raster', type: 'raster', source: 'osm-raster' }],
    },
    center:  [tenant.lon, tenant.lat],
    zoom:    tenant.zoom,
  });

  map.on('load', () => {
    // LGA fill layer
    map!.addSource('lgas', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map!.addLayer({
      id: 'lgas-fill',
      type: 'fill',
      source: 'lgas',
      paint: {
        'fill-color': [
          'case',
          ['in', ['get', 'pcode'], ['literal', selectedLgas.value]],
          '#fbbf24',
          '#3b82f6',
        ],
        'fill-opacity': 0.25,
      },
    });
    map!.addLayer({
      id: 'lgas-outline',
      type: 'line',
      source: 'lgas',
      paint: { 'line-color': '#93c5fd', 'line-width': 1 },
    });

    // Zone fill layer (uses stored color per feature)
    map!.addSource('zones', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map!.addLayer({
      id: 'zones-fill',
      type: 'fill',
      source: 'zones',
      paint: {
        'fill-color': ['coalesce', ['get', 'color'], '#a78bfa'],
        'fill-opacity': 0.45,
      },
    });
    map!.addLayer({
      id: 'zones-outline',
      type: 'line',
      source: 'zones',
      paint: { 'line-color': ['coalesce', ['get', 'color'], '#a78bfa'], 'line-width': 2 },
    });

    // Click on LGA: toggle selection
    map!.on('click', 'lgas-fill', (e) => {
      const feat = e.features?.[0];
      if (!feat) return;
      const pcode = feat.properties?.pcode as string;
      const idx   = selectedLgas.value.indexOf(pcode);
      if (idx >= 0) {
        selectedLgas.value.splice(idx, 1);
      } else {
        selectedLgas.value.push(pcode);
      }
      refreshSelectionLayer();
    });

    // Click on zone: populate edit form
    map!.on('click', 'zones-fill', (e) => {
      const feat = e.features?.[0];
      if (!feat) return;
      const zpcode = feat.properties?.pcode as string;
      const zone   = existingZones.value.find(z => z.zone_pcode === zpcode);
      if (zone) startEdit(zone);
    });

    map!.on('mouseenter', 'lgas-fill',  () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'lgas-fill',  () => { map!.getCanvas().style.cursor = ''; });
    map!.on('mouseenter', 'zones-fill', () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'zones-fill', () => { map!.getCanvas().style.cursor = ''; });

    loadBoundaries();
  });
}

// Redraw LGA selection highlight
function refreshSelectionLayer() {
  if (!map || !map.getLayer('lgas-fill')) return;
  map.setPaintProperty('lgas-fill', 'fill-color', [
    'case',
    ['in', ['get', 'pcode'], ['literal', selectedLgas.value]],
    '#fbbf24',
    '#3b82f6',
  ]);
}

// ---------------------------------------------------------------------------
// Zone CRUD
// ---------------------------------------------------------------------------
async function createZone() {
  if (!zoneName.value.trim()) { setStatus('Zone name is required', 'error'); return; }
  if (selectedLgas.value.length === 0) { setStatus('Select at least one LGA', 'error'); return; }
  if (!adminToken.value) { setStatus('Admin token is required for write operations', 'error'); return; }

  // Derive parent_pcode from the first selected LGA's feature
  const source = map?.getSource('lgas') as maplibregl.GeoJSONSource | undefined;
  // @ts-ignore — _data is internal but accessible
  const features: any[] = source?._data?.features ?? [];
  const firstFeat = features.find((f: any) => f.properties.pcode === selectedLgas.value[0]);
  const parentPcode = firstFeat?.properties?.parent_pcode ?? '';

  if (!parentPcode) { setStatus('Could not determine parent state pcode', 'error'); return; }

  setStatus('Creating zone…');
  try {
    const res = await fetch(`${BASE}/admin/zones`, {
      method: 'POST',
      headers: adminHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({
        zone_name:          zoneName.value.trim(),
        color:              zoneColor.value,
        parent_pcode:       parentPcode,
        constituent_pcodes: selectedLgas.value,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? res.statusText);

    setStatus(`Zone "${data.zone_name}" created (${data.zone_pcode})`, 'success');
    clearForm();
    await loadBoundaries();
  } catch (err: any) {
    setStatus(`Create failed: ${err.message}`, 'error');
  }
}

async function updateZone() {
  if (!editingZone.value) return;
  if (!adminToken.value) { setStatus('Admin token required', 'error'); return; }

  setStatus('Updating zone…');
  try {
    const body: Record<string, any> = { zone_name: zoneName.value, color: zoneColor.value };
    if (selectedLgas.value.length > 0) body.constituent_pcodes = selectedLgas.value;

    const res = await fetch(`${BASE}/admin/zones/${editingZone.value.zone_id}`, {
      method: 'PUT',
      headers: adminHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? res.statusText);

    setStatus(`Zone updated`, 'success');
    clearForm();
    await loadBoundaries();
  } catch (err: any) {
    setStatus(`Update failed: ${err.message}`, 'error');
  }
}

async function deleteZone() {
  if (!editingZone.value) return;
  if (!adminToken.value) { setStatus('Admin token required', 'error'); return; }
  if (!confirm(`Delete zone "${editingZone.value.zone_name}"?`)) return;

  setStatus('Deleting zone…');
  try {
    const res = await fetch(`${BASE}/admin/zones/${editingZone.value.zone_id}`, {
      method: 'DELETE',
      headers: adminHeaders(),
    });
    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.error ?? res.statusText);
    }
    setStatus('Zone deleted', 'success');
    clearForm();
    await loadBoundaries();
  } catch (err: any) {
    setStatus(`Delete failed: ${err.message}`, 'error');
  }
}

function startEdit(zone: Zone) {
  editingZone.value   = zone;
  zoneName.value      = zone.zone_name;
  zoneColor.value     = zone.color ?? '#3b82f6';
  selectedLgas.value  = [...zone.constituent_pcodes];
  refreshSelectionLayer();
  setStatus(`Editing zone: ${zone.zone_name}`);
}

function clearForm() {
  editingZone.value  = null;
  zoneName.value     = '';
  zoneColor.value    = '#3b82f6';
  selectedLgas.value = [];
  refreshSelectionLayer();
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
watch(selectedTenantId, (id) => {
  const tenant = getTenantById(id);
  if (tenant) initMap(tenant);
  clearForm();
});

onMounted(() => {
  const tenant = getTenantById(selectedTenantId.value) ?? TENANTS[0];
  if (tenant && mapContainer.value) initMap(tenant);
});

onUnmounted(() => {
  map?.remove();
  map = null;
});
</script>

<template>
  <div class="zone-root">
    <!-- Sidebar -->
    <aside class="sidebar">
      <h2 class="sidebar-title">Zone Manager</h2>

      <!-- Tenant selector -->
      <div class="form-group">
        <label>Tenant</label>
        <select v-model="selectedTenantId" class="select">
          <option v-for="t in TENANTS" :key="t.id" :value="t.id">
            {{ t.id }} — {{ t.name }}
          </option>
        </select>
      </div>

      <!-- Admin token -->
      <div class="form-group">
        <label>Admin Token <span class="muted">(required for writes)</span></label>
        <input v-model="adminToken" type="password" class="input" placeholder="X-Admin-Token value" />
      </div>

      <hr class="divider" />

      <!-- Zone form -->
      <div class="form-group">
        <label>Zone Name</label>
        <input v-model="zoneName" type="text" class="input" placeholder="e.g. Mainland Cluster" />
      </div>

      <div class="form-group">
        <label>Color</label>
        <div class="color-row">
          <input v-model="zoneColor" type="color" class="color-picker" />
          <span class="muted">{{ zoneColor }}</span>
        </div>
      </div>

      <div class="form-group">
        <label>Selected LGAs <span class="badge">{{ selectedLgas.length }}</span></label>
        <div class="lga-list" v-if="selectedLgas.length > 0">
          <span v-for="p in selectedLgas" :key="p" class="lga-chip">
            {{ p }}
            <button class="chip-remove" @click="selectedLgas.splice(selectedLgas.indexOf(p), 1); refreshSelectionLayer()">×</button>
          </span>
        </div>
        <p class="hint" v-else>Click LGA polygons on the map to select them</p>
      </div>

      <div class="btn-row" v-if="!editingZone">
        <button class="btn btn-primary" @click="createZone">Create Zone</button>
        <button class="btn btn-secondary" @click="loadBoundaries">Refresh</button>
      </div>
      <div class="btn-row" v-else>
        <button class="btn btn-primary"  @click="updateZone">Save Changes</button>
        <button class="btn btn-danger"   @click="deleteZone">Delete Zone</button>
        <button class="btn btn-secondary" @click="clearForm">Cancel</button>
      </div>

      <!-- Status message -->
      <div v-if="statusMsg" :class="['status', statusType]">{{ statusMsg }}</div>

      <hr class="divider" />

      <!-- Existing zones list -->
      <div v-if="existingZones.length > 0">
        <label>Existing Zones</label>
        <div class="zone-list">
          <div
            v-for="z in existingZones" :key="z.zone_id"
            class="zone-item"
            :class="{ active: editingZone?.zone_id === z.zone_id }"
            @click="startEdit(z)"
          >
            <span class="zone-swatch" :style="{ background: z.color ?? '#888' }"></span>
            <span class="zone-item-name">{{ z.zone_name }}</span>
            <span class="muted">{{ z.zone_pcode }}</span>
          </div>
        </div>
      </div>
    </aside>

    <!-- Map -->
    <div ref="mapContainer" class="map-container" />
  </div>
</template>

<style scoped>
.zone-root {
  display: grid;
  grid-template-columns: 340px 1fr;
  height: calc(100vh - 48px);
  background: #020617;
  color: #e5e7eb;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}

.sidebar {
  padding: 16px;
  overflow-y: auto;
  border-right: 1px solid #1e293b;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.sidebar-title {
  font-size: 1rem;
  font-weight: 600;
  color: #f1f5f9;
  margin: 0 0 12px;
}

.form-group { display: flex; flex-direction: column; gap: 4px; margin-bottom: 10px; }
.form-group label { font-size: 0.75rem; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; }

.input, .select {
  background: #0f172a;
  border: 1px solid #334155;
  border-radius: 6px;
  color: #e2e8f0;
  padding: 6px 10px;
  font-size: 0.875rem;
  width: 100%;
}
.input:focus, .select:focus { outline: 2px solid #3b82f6; }

.color-row   { display: flex; align-items: center; gap: 8px; }
.color-picker { width: 40px; height: 32px; border: none; background: none; cursor: pointer; }

.divider { border: none; border-top: 1px solid #1e293b; margin: 12px 0; }

.btn-row { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 4px; }
.btn {
  padding: 6px 14px;
  border-radius: 6px;
  font-size: 0.8rem;
  font-weight: 500;
  cursor: pointer;
  border: none;
}
.btn-primary   { background: #3b82f6; color: white; }
.btn-secondary { background: #334155; color: #e2e8f0; }
.btn-danger    { background: #ef4444; color: white; }
.btn:hover     { opacity: 0.85; }

.status       { font-size: 0.8rem; padding: 6px 10px; border-radius: 6px; margin-top: 8px; }
.status.info  { background: #1e293b; color: #94a3b8; }
.status.error { background: #450a0a; color: #fca5a5; }
.status.success { background: #052e16; color: #86efac; }

.lga-list { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
.lga-chip {
  background: #1e3a5f;
  color: #93c5fd;
  border-radius: 4px;
  padding: 2px 6px;
  font-size: 0.75rem;
  display: flex; align-items: center; gap: 4px;
}
.chip-remove { background: none; border: none; color: #93c5fd; cursor: pointer; padding: 0; font-size: 0.85rem; line-height: 1; }

.badge {
  background: #334155;
  border-radius: 10px;
  padding: 1px 6px;
  font-size: 0.7rem;
  color: #94a3b8;
  margin-left: 4px;
}

.muted { color: #64748b; font-size: 0.75rem; }
.hint  { color: #475569; font-size: 0.75rem; font-style: italic; }

.zone-list  { display: flex; flex-direction: column; gap: 4px; margin-top: 6px; }
.zone-item  { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 6px; cursor: pointer; background: #0f172a; }
.zone-item:hover { background: #1e293b; }
.zone-item.active { background: #1e3a5f; border: 1px solid #3b82f6; }
.zone-swatch { width: 12px; height: 12px; border-radius: 3px; flex-shrink: 0; }
.zone-item-name { flex: 1; font-size: 0.8rem; color: #e2e8f0; }

.map-container { width: 100%; height: 100%; }

@media (max-width: 800px) {
  .zone-root { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
}
</style>
