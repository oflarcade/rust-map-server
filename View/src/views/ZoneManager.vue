<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted } from 'vue';
import { useRouter } from 'vue-router';
import maplibregl from 'maplibre-gl';
import { TENANTS, getTenantById, type TenantConfig } from '../config/tenants';
import { DEFAULT_MARTIN_URL, DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { buildInspectorStyle, loadMartinTileMetadata } from '../map/inspectorStyle';

const router = useRouter();

const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const selectedTenantId = ref(TENANTS[0]?.id ?? '11');
const mapContainer     = ref<HTMLDivElement | null>(null);
const statusMsg        = ref('');
const statusType       = ref<'info' | 'error' | 'success'>('info');

// Zone form
const zoneName        = ref('');
const zoneColor       = ref('#3b82f6');
const zoneTypeLabel   = ref('');
const zoneParentPcode = ref('');    // explicitly chosen parent (state or zone pcode)
const selectedLgas    = ref<string[]>([]);   // pcodes of clicked LGAs
const existingZones   = ref<Zone[]>([]);
const editingZone     = ref<Zone | null>(null);
const hierarchyData   = ref<any>(null);
const allFeatures     = ref<any[]>([]);           // all geojson features for bbox lookup
const activeFeaturePcode = ref<string | null>(null); // sidebar highlight

interface Zone {
  zone_id: number;
  zone_pcode: string;
  zone_name: string;
  color: string;
  parent_pcode: string;
  zone_type_label?: string;
  zone_level: number;
  children_type: 'lga' | 'zone';
  constituent_pcodes: string[];
}

// Flattened boundary tree node (for variable-depth rendering)
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
let loadVersion = 0; // incremented on each initMap; stale loadBoundaries calls bail early

// ---------------------------------------------------------------------------
// Derived: parent options for zone creation (states + zones grouped by level)
// ---------------------------------------------------------------------------
const parentOptions = computed<Array<{ pcode: string; label: string; level: number }>>(() => {
  const opts: Array<{ pcode: string; label: string; level: number }> = [];
  if (!hierarchyData.value) return opts;
  for (const state of (hierarchyData.value.states ?? [])) {
    opts.push({ pcode: state.pcode, label: `${state.name} (state)`, level: 0 });
  }
  for (const z of existingZones.value) {
    const indent = '  '.repeat(z.zone_level);
    opts.push({
      pcode: z.zone_pcode,
      label: `${indent}${z.zone_name} (L${z.zone_level} zone)`,
      level: z.zone_level,
    });
  }
  return opts;
});

// ---------------------------------------------------------------------------
// Derived: flat boundary tree for variable-depth rendering
// ---------------------------------------------------------------------------
const flatBoundaryTree = computed<FlatTreeNode[]>(() => {
  if (!hierarchyData.value) return [];
  const result: FlatTreeNode[] = [];

  function flattenChildren(children: any[], depth: number) {
    for (const child of (children ?? [])) {
      if (child.is_zone || child.zone_pcode) {
        result.push({
          pcode: child.zone_pcode,
          name: child.zone_name ?? child.name,
          depth,
          isZone: true,
          color: child.color,
          level_label: child.zone_type_label,
        });
      } else {
        result.push({
          pcode: child.pcode,
          name: child.name,
          depth,
          isZone: false,
          level_label: child.level_label,
        });
      }
      if (child.children?.length) flattenChildren(child.children, depth + 1);
    }
  }

  for (const state of (hierarchyData.value.states ?? [])) {
    result.push({ pcode: state.pcode, name: state.name, depth: 0, isZone: false, level_label: 'State' });

    if (state.children?.length) {
      // Use new variable-depth children tree when available
      flattenChildren(state.children, 1);
    } else {
      // Fallback: flat lgas + zones (backward compat)
      for (const lga of (state.lgas ?? [])) {
        result.push({ pcode: lga.pcode, name: lga.name, depth: 1, isZone: false });
      }
      for (const zone of (state.zones ?? [])) {
        result.push({ pcode: zone.zone_pcode, name: zone.zone_name, depth: 1, isZone: true, color: zone.color });
      }
    }
  }
  return result;
});

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

// ---------------------------------------------------------------------------
// Load GeoJSON and zones from server
// ---------------------------------------------------------------------------
async function loadBoundaries() {
  if (!map) return;
  const myVersion = loadVersion; // capture at start; if initMap() runs again this becomes stale
  setStatus('Loading boundaries…');

  try {
    // ?t= makes each tenant's URL unique so the browser cache never confuses tenants
    const tid = selectedTenantId.value;
    const [geojsonRes, zonesRes, hierRes] = await Promise.all([
      fetch(`${BASE}/boundaries/geojson?t=${tid}`, { headers: tenantHeaders() }),
      fetch(`${BASE}/admin/zones`,                  { headers: tenantHeaders() }),
      fetch(`${BASE}/boundaries/hierarchy?t=${tid}`, { headers: tenantHeaders() }),
    ]);

    if (myVersion !== loadVersion) return; // tenant changed while fetching

    if (!geojsonRes.ok) throw new Error(`boundaries/geojson: ${geojsonRes.status}`);
    const geojson = await geojsonRes.json();
    if (myVersion !== loadVersion) return;

    if (zonesRes.ok) {
      const zonesData = await zonesRes.json();
      existingZones.value = zonesData.zones ?? [];
    }

    if (hierRes.ok) hierarchyData.value = await hierRes.json();

    // Store all features for bbox lookup (flyToPcode)
    allFeatures.value = geojson.features;

    // Separate LGAs, zones, and states from the FeatureCollection
    const lgaFeatures   = geojson.features.filter((f: any) => f.properties.feature_type === 'lga');
    const zoneFeatures  = geojson.features.filter((f: any) => f.properties.feature_type === 'zone');
    const stateFeatures = geojson.features.filter((f: any) => f.properties.feature_type === 'state');

    // Update or add sources
    if (map.getSource('lgas')) {
      (map.getSource('lgas') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: lgaFeatures });
    }
    if (map.getSource('zones')) {
      (map.getSource('zones') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: zoneFeatures });
    }
    if (map.getSource('states')) {
      (map.getSource('states') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: stateFeatures });
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

    setStatus(`Loaded ${stateFeatures.length} states, ${lgaFeatures.length} LGAs, ${existingZones.value.length} zones`, 'success');
  } catch (err: any) {
    setStatus(`Failed to load: ${err.message}`, 'error');
  }
}

// ---------------------------------------------------------------------------
// Feature info + popup helpers
// ---------------------------------------------------------------------------
function getFeatureInfo(pcode: string): { name: string; parentName: string; type: string } | null {
  if (!hierarchyData.value) return null;
  for (const state of (hierarchyData.value.states ?? [])) {
    if (state.pcode === pcode) return { name: state.name, parentName: hierarchyData.value.name ?? '', type: 'State' };
    for (const lga of (state.lgas ?? [])) {
      if (lga.pcode === pcode) return { name: lga.name, parentName: state.name, type: 'LGA' };
    }
    for (const zone of (state.zones ?? [])) {
      if (zone.zone_pcode === pcode) return { name: zone.zone_name, parentName: state.name, type: 'Zone' };
    }
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
    const rawCoords = feat.geometry.type === 'MultiPolygon'
      ? feat.geometry.coordinates.flat(3)
      : feat.geometry.coordinates.flat(2);
    const bounds = new maplibregl.LngLatBounds();
    rawCoords.forEach((c: number[]) => bounds.extend(c as [number, number]));
    if (!bounds.isEmpty()) {
      const center = bounds.getCenter();
      map.once('moveend', () => {
        if (info) showFeaturePopup([center.lng, center.lat], info.name, info.parentName, info.type);
      });
      map.fitBounds(bounds, { padding: 60, maxZoom: 14, duration: 600 });
    }
  } else if (info) {
    // Fallback: use center coords from hierarchy
    const state = hierarchyData.value?.states?.find((s: any) => s.pcode === pcode);
    if (state?.center_lon && state?.center_lat) {
      map.once('moveend', () => {
        showFeaturePopup([state.center_lon, state.center_lat], info.name, info.parentName, info.type);
      });
      map.flyTo({ center: [state.center_lon, state.center_lat], zoom: 8, duration: 600 });
    }
  }
}

// ---------------------------------------------------------------------------
// Map initialisation
// ---------------------------------------------------------------------------
async function initMap(tenant: TenantConfig) {
  loadVersion++; // invalidate any in-flight initMap/loadBoundaries from previous tenant
  const myVersion = loadVersion;

  if (map) {
    map.remove();
    map = null;
  }

  try {
    setStatus('Loading map…');
    const { baseMeta, boundaryMeta, baseUrl, boundaryUrl } = await loadMartinTileMetadata(
      tenant,
      DEFAULT_MARTIN_URL,
    );
    if (myVersion !== loadVersion) return;

    const style = buildInspectorStyle(baseMeta, boundaryMeta, baseUrl, boundaryUrl);

    map = new maplibregl.Map({
      container: mapContainer.value!,
      style,
      center: [tenant.lon, tenant.lat],
      zoom: tenant.zoom,
    });

    map.addControl(new maplibregl.NavigationControl());
  } catch (err: any) {
    setStatus(`Failed to load map: ${err.message ?? String(err)}`, 'error');
    return;
  }

  map.on('load', () => {
    if (myVersion !== loadVersion) return;
    // LGA layers — transparent fill (clickable hit area) + outline only
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
          'transparent',
        ],
        'fill-opacity': [
          'case',
          ['in', ['get', 'pcode'], ['literal', selectedLgas.value]],
          0.35,
          0,
        ],
      },
    });
    map!.addLayer({
      id: 'lgas-outline',
      type: 'line',
      source: 'lgas',
      paint: { 'line-color': '#60a5fa', 'line-width': 1 },
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

    // State layers (transparent fill for clicks, outline on top)
    map!.addSource('states', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map!.addLayer({
      id: 'states-fill',
      type: 'fill',
      source: 'states',
      paint: { 'fill-color': 'transparent', 'fill-opacity': 0 },
    });
    map!.addLayer({
      id: 'states-outline',
      type: 'line',
      source: 'states',
      paint: { 'line-color': '#1d4ed8', 'line-width': 3, 'line-opacity': 0.8 },
    });

    // Click on LGA: toggle selection + show popup
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
      activeFeaturePcode.value = pcode;
      const info = getFeatureInfo(pcode);
      if (info) showFeaturePopup([e.lngLat.lng, e.lngLat.lat], info.name, info.parentName, info.type);
    });

    // Click on zone: populate edit form + show popup
    map!.on('click', 'zones-fill', (e) => {
      const feat = e.features?.[0];
      if (!feat) return;
      const zpcode = feat.properties?.pcode as string;
      const zone   = existingZones.value.find(z => z.zone_pcode === zpcode);
      if (zone) startEdit(zone);
      activeFeaturePcode.value = zpcode;
      const info = getFeatureInfo(zpcode);
      if (info) showFeaturePopup([e.lngLat.lng, e.lngLat.lat], info.name, info.parentName, info.type);
    });

    // Click on state (only when no LGA/zone underneath)
    map!.on('click', 'states-fill', (e) => {
      const lgaUnder  = map!.queryRenderedFeatures(e.point, { layers: ['lgas-fill'] });
      const zoneUnder = map!.queryRenderedFeatures(e.point, { layers: ['zones-fill'] });
      if (lgaUnder.length > 0 || zoneUnder.length > 0) return;
      const feat = e.features?.[0];
      if (!feat) return;
      const pcode = feat.properties?.pcode as string;
      activeFeaturePcode.value = pcode;
      const info = getFeatureInfo(pcode);
      if (info) showFeaturePopup([e.lngLat.lng, e.lngLat.lat], info.name, info.parentName, info.type);
    });

    map!.on('mouseenter', 'lgas-fill',   () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'lgas-fill',   () => { map!.getCanvas().style.cursor = ''; });
    map!.on('mouseenter', 'zones-fill',  () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'zones-fill',  () => { map!.getCanvas().style.cursor = ''; });
    map!.on('mouseenter', 'states-fill', () => { map!.getCanvas().style.cursor = 'pointer'; });
    map!.on('mouseleave', 'states-fill', () => { map!.getCanvas().style.cursor = ''; });

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
    'transparent',
  ]);
  map.setPaintProperty('lgas-fill', 'fill-opacity', [
    'case',
    ['in', ['get', 'pcode'], ['literal', selectedLgas.value]],
    0.35,
    0,
  ]);
}

// ---------------------------------------------------------------------------
// Zone CRUD
// ---------------------------------------------------------------------------
async function createZone() {
  if (!zoneName.value.trim()) { setStatus('Zone name is required', 'error'); return; }
  if (selectedLgas.value.length === 0) { setStatus('Select at least one LGA', 'error'); return; }

  // Determine parent_pcode: use explicit selection if set, otherwise derive from first LGA
  let parentPcode = zoneParentPcode.value;
  if (!parentPcode) {
    const source = map?.getSource('lgas') as maplibregl.GeoJSONSource | undefined;
    // @ts-ignore — _data is internal but accessible
    const features: any[] = source?._data?.features ?? [];
    const firstFeat = features.find((f: any) => f.properties.pcode === selectedLgas.value[0]);
    parentPcode = firstFeat?.properties?.parent_pcode ?? '';
  }

  if (!parentPcode) { setStatus('Could not determine parent pcode', 'error'); return; }

  // Determine zone_level from parent
  const parentZone = existingZones.value.find(z => z.zone_pcode === parentPcode);
  const zoneLevel  = parentZone ? parentZone.zone_level + 1 : 1;

  setStatus('Creating zone…');
  try {
    const body: Record<string, any> = {
      zone_name:          zoneName.value.trim(),
      color:              zoneColor.value,
      parent_pcode:       parentPcode,
      constituent_pcodes: selectedLgas.value,
      zone_level:         zoneLevel,
    };
    if (zoneTypeLabel.value.trim()) body.zone_type_label = zoneTypeLabel.value.trim();

    const res = await fetch(`${BASE}/admin/zones`, {
      method: 'POST',
      headers: tenantHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(body),
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

  setStatus('Updating zone…');
  try {
    const body: Record<string, any> = { zone_name: zoneName.value, color: zoneColor.value };
    if (zoneTypeLabel.value.trim()) body.zone_type_label = zoneTypeLabel.value.trim();
    if (selectedLgas.value.length > 0) body.constituent_pcodes = selectedLgas.value;

    const res = await fetch(`${BASE}/admin/zones/${editingZone.value.zone_id}`, {
      method: 'PUT',
      headers: tenantHeaders({ 'Content-Type': 'application/json' }),
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
  if (!confirm(`Delete zone "${editingZone.value.zone_name}"?`)) return;

  setStatus('Deleting zone…');
  try {
    const res = await fetch(`${BASE}/admin/zones/${editingZone.value.zone_id}`, {
      method: 'DELETE',
      headers: tenantHeaders(),
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
  editingZone.value     = zone;
  zoneName.value        = zone.zone_name;
  zoneColor.value       = zone.color ?? '#3b82f6';
  zoneTypeLabel.value   = zone.zone_type_label ?? '';
  zoneParentPcode.value = zone.parent_pcode;
  selectedLgas.value    = [...zone.constituent_pcodes];
  refreshSelectionLayer();
  setStatus(`Editing zone: ${zone.zone_name}`);
}

function clearForm() {
  editingZone.value     = null;
  zoneName.value        = '';
  zoneColor.value       = '#3b82f6';
  zoneTypeLabel.value   = '';
  zoneParentPcode.value = '';
  selectedLgas.value    = [];
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
  popup?.remove();
  popup = null;
  map?.remove();
  map = null;
});
</script>

<template>
  <div class="zone-root">
    <!-- Sidebar -->
    <aside class="sidebar">
      <div class="sidebar-header">
        <h2 class="sidebar-title">Zone Manager</h2>
        <button class="back-btn" @click="router.push('/inspector')">← Inspector</button>
      </div>

      <!-- Tenant selector -->
      <div class="form-group">
        <label>Tenant</label>
        <select v-model="selectedTenantId" class="select">
          <option v-for="t in TENANTS" :key="t.id" :value="t.id">
            {{ t.id }} — {{ t.name }}
          </option>
        </select>
      </div>

      <hr class="divider" />

      <!-- Zone form -->
      <div class="form-group">
        <label>Zone Name</label>
        <input v-model="zoneName" type="text" class="input" placeholder="e.g. Mainland Cluster" />
      </div>

      <div class="form-group">
        <label>Zone Type <span class="muted">(optional)</span></label>
        <input v-model="zoneTypeLabel" type="text" class="input" placeholder="e.g. Operational Zone" />
      </div>

      <div class="form-group" v-if="parentOptions.length > 0">
        <label>Parent <span class="muted">(state or zone)</span></label>
        <select v-model="zoneParentPcode" class="select">
          <option value="">— auto-detect from selection —</option>
          <option v-for="opt in parentOptions" :key="opt.pcode" :value="opt.pcode">
            {{ opt.label }}
          </option>
        </select>
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

      <!-- Boundary Tree (variable depth) -->
      <div v-if="flatBoundaryTree.length > 0">
        <hr class="divider" />
        <label>Boundary Tree</label>
        <div class="boundary-tree">
          <button
            v-for="node in flatBoundaryTree"
            :key="node.pcode"
            class="bt-btn"
            :class="{
              'bt-active': activeFeaturePcode === node.pcode,
              'bt-state':  node.depth === 0,
              'bt-zone':   node.isZone,
              'bt-lga':    !node.isZone && node.depth > 0,
            }"
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

    <!-- Map -->
    <div ref="mapContainer" class="map-container" />
  </div>
</template>

<style scoped>
.zone-root {
  display: grid;
  grid-template-columns: 340px 1fr;
  height: 100vh;
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

.sidebar-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}

.sidebar-title {
  font-size: 1rem;
  font-weight: 600;
  color: #f1f5f9;
  margin: 0;
}

.back-btn {
  background: #1e3a5f;
  color: #67e8f9;
  border: 1px solid #1e4d78;
  border-radius: 6px;
  padding: 4px 10px;
  font-size: 12px;
  cursor: pointer;
  white-space: nowrap;
}

.back-btn:hover {
  background: #1e4d78;
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

.boundary-tree { font-size: 0.75rem; max-height: 300px; overflow-y: auto; border: 1px solid #1e293b; border-radius: 6px; padding: 6px; }
.bt-state-group { margin-bottom: 8px; }
.bt-btn {
  display: flex; align-items: center; gap: 6px;
  width: 100%; text-align: left;
  background: none; border: none; cursor: pointer;
  border-radius: 4px; padding: 3px 4px;
  transition: background 0.1s;
}
.bt-btn:hover { background: #1e293b; }
.bt-btn.bt-active { background: #1e3a5f; outline: 1px solid #3b82f6; }
.bt-state { justify-content: space-between; border-bottom: 1px solid #1e293b; margin-bottom: 3px; border-radius: 0; }
.bt-state-name { font-weight: 600; color: #67e8f9; }
.bt-lgas { padding-left: 8px; }
.bt-lga { color: #cbd5e1; }
.bt-zone { color: #c4b5fd; }
.zone-dot-sm { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
.level-pill {
  background: #1e293b;
  color: #64748b;
  border-radius: 3px;
  padding: 1px 4px;
  font-size: 0.65rem;
  margin-left: 4px;
  flex-shrink: 0;
}

@media (max-width: 800px) {
  .zone-root { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
}
</style>
