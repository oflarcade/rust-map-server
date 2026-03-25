<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted } from 'vue';
import { useRouter } from 'vue-router';
import maplibregl from 'maplibre-gl';
import { TENANTS, getTenantById, type TenantConfig } from '../config/tenants';
import { DEFAULT_MARTIN_URL, DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { buildInspectorStyle, loadMartinTileMetadata } from '../map/inspectorStyle';
import ZoneCreatorPanel from '../components/ZoneCreatorPanel.vue';
import type { Zone } from '../types/zone';
import {
  fetchTerritories,
  addTerritories,
  removeTerritory as apiRemoveTerritory,
  type ScopeItem,
  type AvailableItem,
  type TerritoriesResponse,
} from '../api/territories';
import { fetchBoundaryGeoJSON, fetchHierarchy } from '../api/boundaries';

const router = useRouter();
const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

// ── Global state ──────────────────────────────────────────────────────────
const selectedTenantId = ref(TENANTS[0]?.id ?? '11');
const mapContainer     = ref<HTMLDivElement | null>(null);
const statusMsg        = ref('');
const statusType       = ref<'info' | 'error' | 'success'>('info');
const activeTab        = ref<'create' | 'territories'>('create');

// Zone state
const existingZones    = ref<Zone[]>([]);
const editingZone      = ref<Zone | null>(null);
const zoneName         = ref('');
const zoneColor        = ref('#3b82f6');
const zoneTypeLabel    = ref('');
const hierarchyData    = ref<any>(null);
const allFeatures      = ref<any[]>([]);
const activeFeaturePcode = ref<string | null>(null);

// Territories state
const territories      = ref<TerritoriesResponse | null>(null);
const territoriesLoading = ref(false);
const showAvailable    = ref(false);
const availableSearch  = ref('');
const selectedAvailable = ref<string[]>([]);

interface FlatTreeNode {
  pcode: string;
  name: string;
  depth: number;
  isZone: boolean;
  color?: string;
  level_label?: string;
}

let map: maplibregl.Map | null = null;
let popup: maplibregl.Popup | null = null;
let loadVersion = 0;

// ── Computed ──────────────────────────────────────────────────────────────
const selectedTenantConfig = computed(() => getTenantById(selectedTenantId.value));

const flatBoundaryTree = computed<FlatTreeNode[]>(() => {
  if (!hierarchyData.value) return [];
  const result: FlatTreeNode[] = [];
  function flattenChildren(children: any[], depth: number) {
    for (const child of (children ?? [])) {
      if (child.is_zone || child.zone_pcode) {
        result.push({ pcode: child.zone_pcode, name: child.zone_name ?? child.name, depth, isZone: true, color: child.color, level_label: child.zone_type_label });
      } else {
        result.push({ pcode: child.pcode, name: child.name, depth, isZone: false, level_label: child.level_label });
      }
      if (child.children?.length) flattenChildren(child.children, depth + 1);
    }
  }
  for (const state of (hierarchyData.value.states ?? [])) {
    result.push({ pcode: state.pcode, name: state.name, depth: 0, isZone: false, level_label: 'State' });
    if (state.children?.length) flattenChildren(state.children, 1);
    else {
      for (const adm2 of (state.adm2s ?? [])) result.push({ pcode: adm2.pcode, name: adm2.name, depth: 1, isZone: false });
      for (const zone of (state.zones ?? [])) result.push({ pcode: zone.zone_pcode, name: zone.zone_name, depth: 1, isZone: true, color: zone.color });
    }
  }
  return result;
});

const filteredAvailable = computed(() => {
  const q = availableSearch.value.toLowerCase();
  const items = territories.value?.available ?? [];
  if (!q) return items;
  return items.filter(a => a.name.toLowerCase().includes(q) || a.pcode.toLowerCase().includes(q) || a.parent_name.toLowerCase().includes(q));
});

const availableByState = computed(() => {
  const groups: Record<string, { stateName: string; items: AvailableItem[] }> = {};
  for (const item of filteredAvailable.value) {
    if (!groups[item.parent_pcode]) groups[item.parent_pcode] = { stateName: item.parent_name, items: [] };
    groups[item.parent_pcode].items.push(item);
  }
  return Object.entries(groups).map(([k, v]) => ({ pcode: k, stateName: v.stateName, items: v.items }));
});

// ── Helpers ───────────────────────────────────────────────────────────────
function setStatus(msg: string, type: 'info' | 'error' | 'success' = 'info') {
  statusMsg.value = msg; statusType.value = type;
}
function tenantHeaders(extra: Record<string, string> = {}) {
  return { 'X-Tenant-ID': selectedTenantId.value, ...extra };
}

// ── Boundary loading ──────────────────────────────────────────────────────
async function loadBoundaries() {
  if (!map) return;
  const myVersion = loadVersion;
  setStatus('Loading boundaries…');
  try {
    const tid = selectedTenantId.value;
    const [geojson, zonesRes, hier] = await Promise.all([
      fetchBoundaryGeoJSON(tid),
      fetch(`${BASE}/admin/zones`, { headers: tenantHeaders() }),
      fetchHierarchy(tid),
    ]);
    if (myVersion !== loadVersion) return;
    if (zonesRes.ok) { const d = await zonesRes.json(); existingZones.value = d.zones ?? []; }
    hierarchyData.value = hier;
    allFeatures.value = geojson.features;
    const lgaFeatures   = geojson.features.filter((f: any) => f.properties.feature_type === 'adm2');
    const zoneFeatures  = geojson.features.filter((f: any) => f.properties.feature_type === 'zone');
    const stateFeatures = geojson.features.filter((f: any) => f.properties.feature_type === 'state');
    if (map.getSource('lgas'))   (map.getSource('lgas')   as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: lgaFeatures });
    if (map.getSource('zones'))  (map.getSource('zones')  as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: zoneFeatures });
    if (map.getSource('states')) (map.getSource('states') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: stateFeatures });
    if (geojson.features.length > 0) {
      const bounds = new maplibregl.LngLatBounds();
      geojson.features.forEach((f: any) => {
        if (f.geometry?.coordinates) {
          const coords = f.geometry.type === 'MultiPolygon' ? f.geometry.coordinates.flat(2) : f.geometry.coordinates.flat(1);
          coords.forEach((c: number[]) => bounds.extend(c as [number, number]));
        }
      });
      if (!bounds.isEmpty()) map.fitBounds(bounds, { padding: 40, duration: 800 });
    }
    setStatus(`Loaded ${stateFeatures.length} states, ${lgaFeatures.length} LGAs, ${existingZones.value.length} zones`, 'success');
  } catch (err: any) {
    setStatus(`Failed to load: ${err.message}`, 'error');
  }
}

// ── Territories API ───────────────────────────────────────────────────────
async function loadTerritories() {
  territoriesLoading.value = true;
  try {
    territories.value = await fetchTerritories(selectedTenantId.value);
  } catch (e: any) {
    setStatus(`Territories error: ${e.message}`, 'error');
  } finally {
    territoriesLoading.value = false;
  }
}

async function addSelectedTerritories() {
  if (selectedAvailable.value.length === 0) return;
  try {
    const data = await addTerritories(selectedTenantId.value, selectedAvailable.value);
    setStatus(`Added ${data.added} pcodes to scope`, 'success');
    selectedAvailable.value = [];
    showAvailable.value = false;
    await loadTerritories();
    await loadBoundaries();
  } catch (e: any) {
    setStatus(`Add territories failed: ${e.message}`, 'error');
  }
}

async function removeTerritory(pcode: string, name: string) {
  if (!confirm(`Remove "${name}" (${pcode}) from this tenant's scope?\n\nThis will break any zones that use this pcode.`)) return;
  try {
    await apiRemoveTerritory(selectedTenantId.value, pcode);
    setStatus(`Removed ${pcode} from scope`, 'success');
    await loadTerritories();
    await loadBoundaries();
  } catch (e: any) {
    setStatus(`Remove failed: ${e.message}`, 'error');
  }
}

function toggleAvailablePcode(pcode: string) {
  const idx = selectedAvailable.value.indexOf(pcode);
  if (idx >= 0) selectedAvailable.value.splice(idx, 1);
  else selectedAvailable.value.push(pcode);
}

// ── Feature info / popup ──────────────────────────────────────────────────
function getFeatureInfo(pcode: string): { name: string; parentName: string; type: string } | null {
  if (!hierarchyData.value) return null;
  for (const state of (hierarchyData.value.states ?? [])) {
    if (state.pcode === pcode) return { name: state.name, parentName: hierarchyData.value.name ?? '', type: 'State' };
    for (const adm2 of (state.adm2s ?? [])) if (adm2.pcode === pcode) return { name: adm2.name, parentName: state.name, type: 'LGA' };
    for (const zone of (state.zones ?? [])) if (zone.zone_pcode === pcode) return { name: zone.zone_name, parentName: state.name, type: 'Zone' };
  }
  return null;
}

function showFeaturePopup(lngLat: [number, number], name: string, parentName: string, type: string) {
  if (popup) { popup.remove(); popup = null; }
  if (!map) return;
  popup = new maplibregl.Popup({ closeButton: true, maxWidth: '240px' })
    .setLngLat(lngLat)
    .setHTML(
      `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">${type}</div>` +
      `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${name}</div>` +
      (parentName ? `<div style="font-size:11px;color:#475569;margin-top:3px">${parentName}</div>` : '')
    )
    .addTo(map);
}

function flyToPcode(pcode: string) {
  if (!map) return;
  activeFeaturePcode.value = pcode;
  const feat = allFeatures.value.find((f: any) => f.properties?.pcode === pcode);
  const info = getFeatureInfo(pcode);
  if (feat?.geometry) {
    const rawCoords = feat.geometry.type === 'MultiPolygon' ? feat.geometry.coordinates.flat(3) : feat.geometry.coordinates.flat(2);
    const bounds = new maplibregl.LngLatBounds();
    rawCoords.forEach((c: number[]) => bounds.extend(c as [number, number]));
    if (!bounds.isEmpty()) {
      const center = bounds.getCenter();
      map.once('moveend', () => { if (info) showFeaturePopup([center.lng, center.lat], info.name, info.parentName, info.type); });
      map.fitBounds(bounds, { padding: 60, maxZoom: 14, duration: 600 });
    }
  }
}

// ── Map initialisation ────────────────────────────────────────────────────
async function initMap(tenant: TenantConfig) {
  loadVersion++;
  const myVersion = loadVersion;
  if (map) { map.remove(); map = null; }
  try {
    setStatus('Loading map…');
    const { baseMeta, boundaryMeta, baseUrl, boundaryUrl } = await loadMartinTileMetadata(tenant, DEFAULT_MARTIN_URL);
    if (myVersion !== loadVersion) return;
    const style = buildInspectorStyle(baseMeta, boundaryMeta, baseUrl, boundaryUrl);
    map = new maplibregl.Map({ container: mapContainer.value!, style, center: [tenant.lon, tenant.lat], zoom: tenant.zoom });
    map.addControl(new maplibregl.NavigationControl());
  } catch (err: any) {
    setStatus(`Failed to load map: ${err.message ?? String(err)}`, 'error'); return;
  }

  map.on('load', () => {
    if (myVersion !== loadVersion) return;
    map!.addSource('lgas',   { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map!.addLayer({ id: 'lgas-fill', type: 'fill', source: 'lgas', paint: { 'fill-color': 'transparent', 'fill-opacity': 0 } });
    map!.addLayer({ id: 'lgas-outline', type: 'line', source: 'lgas', paint: { 'line-color': '#60a5fa', 'line-width': 1 } });

    map!.addSource('zones', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map!.addLayer({ id: 'zones-fill', type: 'fill', source: 'zones', filter: ['any', ['==', ['get', 'zone_level'], 2], ['!', ['has', 'zone_level']]], paint: { 'fill-color': ['coalesce', ['get', 'color'], '#a78bfa'], 'fill-opacity': 0.45 } });
    map!.addLayer({ id: 'zones-outline', type: 'line', source: 'zones', filter: ['any', ['==', ['get', 'zone_level'], 2], ['!', ['has', 'zone_level']]], paint: { 'line-color': ['coalesce', ['get', 'color'], '#a78bfa'], 'line-width': 2 } });
    map!.addLayer({ id: 'zones-outline-level1', type: 'line', source: 'zones', filter: ['==', ['get', 'zone_level'], 1], paint: { 'line-color': ['coalesce', ['get', 'color'], '#f59e0b'], 'line-width': 4, 'line-dasharray': [4, 2] } });

    map!.addSource('states', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map!.addLayer({ id: 'states-fill', type: 'fill', source: 'states', paint: { 'fill-color': 'transparent', 'fill-opacity': 0 } });
    map!.addLayer({ id: 'states-outline', type: 'line', source: 'states', paint: { 'line-color': '#1d4ed8', 'line-width': 3, 'line-opacity': 0.8 } });

    // Click zone → enter edit mode
    map!.on('click', 'zones-fill', (e) => {
      const feat = e.features?.[0];
      if (!feat) return;
      const zpcode = feat.properties?.pcode as string;
      const zone = existingZones.value.find(z => z.zone_pcode === zpcode);
      if (zone) startEdit(zone);
      activeFeaturePcode.value = zpcode;
      const info = getFeatureInfo(zpcode);
      if (info) showFeaturePopup([e.lngLat.lng, e.lngLat.lat], info.name, info.parentName, info.type);
    });
    map!.on('click', 'zones-outline-level1', (e) => {
      const feat = e.features?.[0];
      if (!feat) return;
      const zpcode = feat.properties?.pcode as string;
      const zone = existingZones.value.find(z => z.zone_pcode === zpcode);
      if (zone) startEdit(zone);
      activeFeaturePcode.value = zpcode;
      const info = getFeatureInfo(zpcode);
      if (info) showFeaturePopup([e.lngLat.lng, e.lngLat.lat], info.name, info.parentName, info.type);
    });
    map!.on('click', 'states-fill', (e) => {
      const zoneUnder = map!.queryRenderedFeatures(e.point, { layers: ['zones-fill', 'zones-outline-level1'] });
      if (zoneUnder.length > 0) return;
      const feat = e.features?.[0];
      if (!feat) return;
      const pcode = feat.properties?.pcode as string;
      activeFeaturePcode.value = pcode;
      const info = getFeatureInfo(pcode);
      if (info) showFeaturePopup([e.lngLat.lng, e.lngLat.lat], info.name, info.parentName, info.type);
    });

    map!.on('mouseenter', 'zones-fill',           () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'zones-fill',           () => { map!.getCanvas().style.cursor = ''; });
    map!.on('mouseenter', 'zones-outline-level1', () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'zones-outline-level1', () => { map!.getCanvas().style.cursor = ''; });
    map!.on('mouseenter', 'states-fill', () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'states-fill', () => { map!.getCanvas().style.cursor = ''; });

    loadBoundaries();
  });
}

// ── Zone edit/delete ──────────────────────────────────────────────────────
function startEdit(zone: Zone) {
  editingZone.value   = zone;
  zoneName.value      = zone.zone_name;
  zoneColor.value     = zone.color ?? '#3b82f6';
  zoneTypeLabel.value = zone.zone_type_label ?? '';
  setStatus(`Editing: ${zone.zone_name}`);
}

function clearEdit() {
  editingZone.value = null;
  zoneName.value = '';
  zoneColor.value = '#3b82f6';
  zoneTypeLabel.value = '';
  statusMsg.value = '';
}

async function updateZone() {
  if (!editingZone.value) return;
  setStatus('Updating zone…');
  try {
    const body: Record<string, any> = { zone_name: zoneName.value, color: zoneColor.value };
    if (zoneTypeLabel.value.trim()) body.zone_type_label = zoneTypeLabel.value.trim();
    const res = await fetch(`${BASE}/admin/zones/${editingZone.value.id}`, {
      method: 'PUT',
      headers: tenantHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? res.statusText);
    setStatus('Zone updated', 'success');
    clearEdit();
    await loadBoundaries();
  } catch (err: any) {
    setStatus(`Update failed: ${err.message}`, 'error');
  }
}

async function deleteZone() {
  if (!editingZone.value) return;
  if (!confirm(`Delete zone "${editingZone.value.zone_name}"?`)) return;
  setStatus('Deleting zone…');
  try {
    const res = await fetch(`${BASE}/admin/zones/${editingZone.value.id}`, {
      method: 'DELETE', headers: tenantHeaders(),
    });
    if (!res.ok) { const d = await res.json(); throw new Error(d.error ?? res.statusText); }
    setStatus('Zone deleted', 'success');
    clearEdit();
    await loadBoundaries();
  } catch (err: any) {
    setStatus(`Delete failed: ${err.message}`, 'error');
  }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────
watch(selectedTenantId, (id) => {
  const tenant = getTenantById(id);
  if (tenant) initMap(tenant);
  clearEdit();
  territories.value = null;
  if (activeTab.value === 'territories') loadTerritories();
});

watch(activeTab, (tab) => {
  if (tab === 'territories' && !territories.value) loadTerritories();
});

onMounted(() => {
  const tenant = getTenantById(selectedTenantId.value) ?? TENANTS[0];
  if (tenant && mapContainer.value) initMap(tenant);
});

onUnmounted(() => { popup?.remove(); popup = null; map?.remove(); map = null; });
</script>

<template>
  <div class="zone-root">
    <!-- ── Sidebar ──────────────────────────────────────────────────── -->
    <aside class="sidebar">
      <div class="sidebar-header">
        <h2 class="sidebar-title">Tenant Administrative Manager</h2>
        <button class="back-btn" @click="router.push('/inspector')">← Inspector</button>
      </div>

      <!-- Tenant selector -->
      <div class="form-group">
        <label>Tenant</label>
        <select v-model="selectedTenantId" class="select">
          <option v-for="t in TENANTS" :key="t.id" :value="t.id">{{ t.id }} — {{ t.name }}</option>
        </select>
      </div>

      <!-- Tab nav -->
      <div class="tab-nav">
        <button :class="['tab-btn', { active: activeTab === 'create' }]" @click="activeTab = 'create'">Create Zone</button>
        <button :class="['tab-btn', { active: activeTab === 'territories' }]" @click="activeTab = 'territories'">Territories</button>
      </div>

      <!-- ── Tab: Create Zone ────────────────────────────────────────── -->
      <div v-if="activeTab === 'create'" class="tab-content">
        <!-- Editing an existing zone -->
        <div v-if="editingZone" class="edit-panel">
          <div class="edit-head">
            <span>Editing: <strong>{{ editingZone.zone_name }}</strong></span>
            <button class="link-btn" @click="clearEdit">✕ Cancel</button>
          </div>
          <div class="form-group">
            <label>Name</label>
            <input v-model="zoneName" type="text" class="input" />
          </div>
          <div class="form-group">
            <label>Type <span class="muted">(optional)</span></label>
            <input v-model="zoneTypeLabel" type="text" class="input" placeholder="e.g. Cluster" />
          </div>
          <div class="form-group">
            <label>Color</label>
            <div class="color-row">
              <input v-model="zoneColor" type="color" class="color-picker" />
              <span class="muted">{{ zoneColor }}</span>
            </div>
          </div>
          <div class="btn-row">
            <button class="btn btn-primary"  @click="updateZone">Save</button>
            <button class="btn btn-danger"   @click="deleteZone">Delete</button>
            <button class="btn btn-secondary" @click="clearEdit">Cancel</button>
          </div>
        </div>

        <!-- ZoneCreatorPanel -->
        <div v-else class="creator-wrap">
          <ZoneCreatorPanel
            :tenant-id="selectedTenantId"
            :base-url="BASE"
            :zone-types="selectedTenantConfig?.zoneTypes"
            @zone-created="loadBoundaries"
          />
        </div>
      </div>

      <!-- ── Tab: Territories ───────────────────────────────────────── -->
      <div v-else class="tab-content territories-tab">
        <div v-if="territoriesLoading" class="hint">Loading territories…</div>
        <template v-else-if="territories">
          <!-- In-scope table -->
          <div class="terr-head">
            In Scope
            <span class="badge">{{ territories.in_scope.length }}</span>
          </div>
          <div class="scope-list">
            <div v-for="item in territories.in_scope" :key="item.pcode" class="scope-row">
              <span class="scope-name">{{ item.name }}</span>
              <span class="muted scope-meta">L{{ item.adm_level }} · {{ item.children_count }} children</span>
              <button class="scope-remove" @click="removeTerritory(item.pcode, item.name)" title="Remove from scope">×</button>
            </div>
            <div v-if="territories.in_scope.length === 0" class="hint">No features in scope.</div>
          </div>

          <!-- Expand to add -->
          <div class="terr-expand-bar">
            <button class="btn btn-secondary btn-sm" @click="showAvailable = !showAvailable">
              {{ showAvailable ? '▾ Hide' : '▸ Add LGAs' }} ({{ territories.available.length }} available)
            </button>
          </div>

          <div v-if="showAvailable" class="available-panel">
            <input v-model="availableSearch" class="input" placeholder="Search available…" />
            <div class="avail-groups">
              <div v-for="group in availableByState" :key="group.pcode" class="avail-group">
                <div class="avail-state-name">{{ group.stateName }}</div>
                <label v-for="item in group.items" :key="item.pcode" class="avail-item">
                  <input type="checkbox" :checked="selectedAvailable.includes(item.pcode)" @change="toggleAvailablePcode(item.pcode)" />
                  {{ item.name }}
                  <span class="muted">{{ item.pcode }}</span>
                </label>
              </div>
              <div v-if="availableByState.length === 0" class="hint">No available LGAs match.</div>
            </div>
            <div class="btn-row" v-if="selectedAvailable.length > 0">
              <button class="btn btn-primary btn-sm" @click="addSelectedTerritories">
                Add {{ selectedAvailable.length }} to Scope
              </button>
              <button class="btn btn-secondary btn-sm" @click="selectedAvailable = []">Clear</button>
            </div>
          </div>
        </template>
        <div v-else class="hint">
          <button class="btn btn-secondary btn-sm" @click="loadTerritories">Load territories</button>
        </div>
      </div>

      <!-- Status message -->
      <div v-if="statusMsg" :class="['status', statusType]">{{ statusMsg }}</div>

      <hr class="divider" />

      <!-- Existing zones list (for editing) -->
      <div v-if="existingZones.length > 0">
        <label>Existing Areas <span class="muted">(click to edit)</span></label>
        <div class="zone-list">
          <div
            v-for="z in existingZones" :key="z.id"
            class="zone-item"
            :class="{ active: editingZone?.id === z.id }"
            @click="startEdit(z)"
          >
            <span class="zone-swatch" :style="{ background: z.color ?? '#888' }"></span>
            <span class="zone-item-name">{{ z.zone_name }}</span>
            <span class="muted">{{ z.zone_pcode }}</span>
          </div>
        </div>
      </div>

      <!-- Boundary tree reference -->
      <div v-if="flatBoundaryTree.length > 0">
        <hr class="divider" />
        <label>Boundary Tree <span class="muted">(click to fly)</span></label>
        <div class="boundary-tree">
          <button
            v-for="node in flatBoundaryTree" :key="node.pcode"
            class="bt-btn"
            :class="{ 'bt-active': activeFeaturePcode === node.pcode, 'bt-state': node.depth === 0, 'bt-zone': node.isZone, 'bt-lga': !node.isZone && node.depth > 0 }"
            :style="{ paddingLeft: (node.depth * 12 + 4) + 'px' }"
            @click="flyToPcode(node.pcode)"
          >
            <span v-if="node.isZone" class="zone-dot-sm" :style="{ background: node.color ?? '#a78bfa' }"></span>
            <span v-if="node.depth === 0" class="bt-state-name">{{ node.name }}</span>
            <span v-else>{{ node.name }}</span>
            <span class="muted">{{ node.pcode }}</span>
            <span v-if="node.level_label && node.depth > 0" class="level-pill">{{ node.level_label }}</span>
          </button>
        </div>
      </div>
    </aside>

    <!-- ── Map ───────────────────────────────────────────────────────── -->
    <div ref="mapContainer" class="map-container" />
  </div>
</template>

<style scoped>
.zone-root {
  display: grid;
  grid-template-columns: 520px 1fr;
  height: 100vh;
  background: #f8fafc;
  color: #1e293b;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}

.sidebar {
  padding: 14px;
  overflow-y: auto;
  border-right: 1px solid #e2e8f0;
  display: flex;
  flex-direction: column;
  gap: 4px;
  background: #f8fafc;
}

.sidebar-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 10px;
}

.sidebar-title { font-size: 0.95rem; font-weight: 600; color: #0f172a; margin: 0; }

.back-btn {
  background: #eff6ff;
  color: #1d4ed8;
  border: 1px solid #bfdbfe;
  border-radius: 6px;
  padding: 4px 10px;
  font-size: 12px;
  cursor: pointer;
  white-space: nowrap;
}
.back-btn:hover { background: #dbeafe; }

.form-group { display: flex; flex-direction: column; gap: 4px; margin-bottom: 8px; }
.form-group label { font-size: 0.7rem; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; }

.input, .select {
  background: #ffffff;
  border: 1px solid #cbd5e1;
  border-radius: 6px;
  color: #1e293b;
  padding: 6px 10px;
  font-size: 0.875rem;
  width: 100%;
}
.input:focus, .select:focus { outline: 2px solid #3b82f6; }

.color-row { display: flex; align-items: center; gap: 8px; }
.color-picker { width: 40px; height: 32px; border: none; background: none; cursor: pointer; }

/* Tabs */
.tab-nav { display: flex; border-bottom: 1px solid #e2e8f0; margin-bottom: 10px; }
.tab-btn { flex: 1; background: none; border: none; border-bottom: 2px solid transparent; padding: 7px 0; font-size: 12px; font-weight: 500; color: #64748b; cursor: pointer; transition: color 0.15s, border-color 0.15s; }
.tab-btn:hover { color: #1e293b; }
.tab-btn.active { color: #1d4ed8; border-bottom-color: #1d4ed8; }

.tab-content { min-height: 0; }

/* Create zone / edit panel */
.edit-panel { background: #fffbeb; border: 1px solid #fde68a; border-radius: 8px; padding: 10px; margin-bottom: 10px; }
.edit-head { display: flex; align-items: center; justify-content: space-between; font-size: 12px; color: #92400e; margin-bottom: 8px; }
.link-btn { background: none; border: none; cursor: pointer; color: #92400e; font-size: 12px; }
.creator-wrap { height: 380px; border: 1px solid #e2e8f0; border-radius: 8px; overflow: hidden; }

/* Territories tab */
.territories-tab { display: flex; flex-direction: column; gap: 8px; }
.terr-head { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: #64748b; display: flex; align-items: center; gap: 6px; }
.scope-list { display: flex; flex-direction: column; gap: 2px; max-height: 180px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 6px; padding: 6px; }
.scope-row { display: flex; align-items: center; gap: 6px; padding: 3px 4px; border-radius: 4px; font-size: 12px; }
.scope-row:hover { background: #f1f5f9; }
.scope-name { flex: 1; }
.scope-meta { font-size: 11px; }
.scope-remove { background: none; border: none; cursor: pointer; color: #94a3b8; font-size: 14px; line-height: 1; padding: 0 2px; }
.scope-remove:hover { color: #dc2626; }
.terr-expand-bar { margin-top: 4px; }
.available-panel { border: 1px solid #e2e8f0; border-radius: 6px; padding: 8px; display: flex; flex-direction: column; gap: 6px; }
.avail-groups { max-height: 200px; overflow-y: auto; display: flex; flex-direction: column; gap: 6px; }
.avail-state-name { font-size: 11px; font-weight: 600; color: #0369a1; padding: 2px 0; border-bottom: 1px solid #e2e8f0; margin-bottom: 2px; }
.avail-item { display: flex; align-items: center; gap: 5px; font-size: 11px; color: #334155; padding: 2px 4px; border-radius: 3px; cursor: pointer; }
.avail-item:hover { background: #f1f5f9; }
.avail-item input { accent-color: #2563eb; flex-shrink: 0; }

/* Dividers and common */
.divider { border: none; border-top: 1px solid #e2e8f0; margin: 10px 0; }
.muted { color: #94a3b8; font-size: 0.75rem; }
.hint  { color: #94a3b8; font-size: 0.75rem; font-style: italic; padding: 4px 0; }
.badge { background: #dbeafe; color: #1d4ed8; border-radius: 10px; padding: 1px 6px; font-size: 10px; }

.btn-row { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 4px; }
.btn { padding: 6px 14px; border-radius: 6px; font-size: 0.8rem; font-weight: 500; cursor: pointer; border: none; }
.btn-sm { padding: 4px 10px; font-size: 11px; }
.btn-primary   { background: #2563eb; color: white; }
.btn-secondary { background: #f1f5f9; color: #334155; border: 1px solid #e2e8f0; }
.btn-danger    { background: #ef4444; color: white; }
.btn:hover     { opacity: 0.85; }

.status         { font-size: 0.8rem; padding: 6px 10px; border-radius: 6px; margin-top: 8px; }
.status.info    { background: #f1f5f9; color: #475569; }
.status.error   { background: #fef2f2; color: #991b1b; }
.status.success { background: #f0fdf4; color: #166534; }

/* Zone list */
.zone-list { display: flex; flex-direction: column; gap: 3px; margin-top: 6px; }
.zone-item { display: flex; align-items: center; gap: 8px; padding: 5px 8px; border-radius: 6px; cursor: pointer; background: #f8fafc; border: 1px solid #e2e8f0; }
.zone-item:hover { background: #f1f5f9; }
.zone-item.active { background: #eff6ff; border-color: #3b82f6; }
.zone-swatch { width: 12px; height: 12px; border-radius: 3px; flex-shrink: 0; }
.zone-item-name { flex: 1; font-size: 0.8rem; color: #1e293b; }

/* Boundary tree */
.map-container { width: 100%; height: 100%; }
.boundary-tree { font-size: 0.75rem; max-height: 260px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 6px; padding: 6px; }
.bt-btn { display: flex; align-items: center; gap: 6px; width: 100%; text-align: left; background: none; border: none; cursor: pointer; border-radius: 4px; padding: 3px 4px; transition: background 0.1s; }
.bt-btn:hover { background: #f1f5f9; }
.bt-btn.bt-active { background: #eff6ff; outline: 1px solid #3b82f6; }
.bt-state { justify-content: space-between; border-bottom: 1px solid #e2e8f0; margin-bottom: 3px; border-radius: 0; }
.bt-state-name { font-weight: 600; color: #0369a1; }
.bt-lga { color: #475569; }
.bt-zone { color: #1e40af; }
.zone-dot-sm { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
.level-pill { background: #e2e8f0; color: #64748b; border-radius: 3px; padding: 1px 4px; font-size: 0.65rem; margin-left: 4px; flex-shrink: 0; }

@media (max-width: 900px) {
  .zone-root { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
  .creator-wrap { height: 300px; }
}
</style>
