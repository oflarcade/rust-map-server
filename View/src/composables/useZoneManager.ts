import { ref, watch } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from './useTileInspector';

export interface Zone {
  id: number;
  zone_pcode: string;
  zone_name: string;
  color: string | null;
  zone_level: number;
  zone_type_label: string | null;
  parent_pcode: string | null;
  children_type: 'lga' | 'zone';
  constituent_pcodes: string[];
  updated_by: string | null;
}

// Module-level state shared across callers
const zones = ref<Zone[]>([]);
const loadingZones = ref(false);
const editingZone = ref<Zone | null>(null);
const creatingZone = ref(false);

let watcherRegistered = false;

export function useZoneManager() {
  const { selectedTenantId, loadHierarchy, loadZoneOverlay } = useTileInspector();
  const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

  async function loadZones(): Promise<void> {
    loadingZones.value = true;
    try {
      const res = await fetch(`${BASE}/admin/zones`, {
        headers: { 'X-Tenant-ID': selectedTenantId.value },
      });
      if (res.ok) {
        const data = await res.json();
        zones.value = data.zones ?? [];
      }
    } catch { /* ignore */ } finally {
      loadingZones.value = false;
    }
  }

  async function deleteZone(id: number): Promise<void> {
    await fetch(`${BASE}/admin/zones/${id}`, {
      method: 'DELETE',
      headers: { 'X-Tenant-ID': selectedTenantId.value },
    });
    await loadZones();
    loadHierarchy();
    loadZoneOverlay();
  }

  async function saveZone(payload: Record<string, unknown>): Promise<boolean> {
    const isEdit = !!editingZone.value;
    const url = isEdit ? `${BASE}/admin/zones/${editingZone.value!.id}` : `${BASE}/admin/zones`;
    const method = isEdit ? 'PUT' : 'POST';
    const res = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': selectedTenantId.value },
      body: JSON.stringify(payload),
    });
    if (!res.ok) return false;
    editingZone.value = null;
    creatingZone.value = false;
    await loadZones();
    loadHierarchy();
    loadZoneOverlay();
    return true;
  }

  function startEdit(zone: Zone) {
    editingZone.value = zone;
    creatingZone.value = false;
  }

  function startCreate() {
    editingZone.value = null;
    creatingZone.value = true;
  }

  function cancelForm() {
    editingZone.value = null;
    creatingZone.value = false;
  }

  if (!watcherRegistered) {
    watcherRegistered = true;
    watch(selectedTenantId, () => {
      zones.value = [];
      editingZone.value = null;
      creatingZone.value = false;
      loadZones();
    });
  }

  return {
    zones,
    loadingZones,
    editingZone,
    creatingZone,
    loadZones,
    saveZone,
    deleteZone,
    startEdit,
    startCreate,
    cancelForm,
  };
}
