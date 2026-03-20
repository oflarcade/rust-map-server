import { computed, ref, watch } from 'vue';
import { useQuery, useMutation, useQueryClient } from '@tanstack/vue-query';
import { fetchZones, createZone, updateZone, deleteZone as apiDeleteZone } from '../api/zones';
import type { Zone, ZoneCreatePayload, ZoneUpdatePayload } from '../types/zone';
import { useTileInspector } from './useTileInspector';

export type { Zone } from '../types/zone';

// Module-level UI state shared across callers
const editingZone = ref<Zone | null>(null);
const creatingZone = ref(false);

let watcherRegistered = false;

export function useZoneManager() {
  const { selectedTenantId, loadHierarchy, loadZoneOverlay } = useTileInspector();
  const queryClient = useQueryClient();

  // Zones list query — auto-fetches and re-fetches when tenant changes
  const { data: zones, isLoading: loadingZones } = useQuery({
    queryKey: computed(() => ['tenant', selectedTenantId.value, 'zones']),
    queryFn: () => fetchZones(selectedTenantId.value),
    placeholderData: [] as Zone[],
  });

  // Invalidate all queries for the current tenant (zones + hierarchy + geojson)
  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: ['tenant', selectedTenantId.value] });

  // Delete mutation
  const deleteMutation = useMutation({
    mutationFn: (id: number) => apiDeleteZone(selectedTenantId.value, id),
    onSuccess: () => {
      loadHierarchy();
      loadZoneOverlay();
      invalidate();
    },
  });

  // Save mutation (create or update)
  const saveMutation = useMutation({
    mutationFn: (payload: { isEdit: boolean; id?: number; data: ZoneCreatePayload }) =>
      payload.isEdit && payload.id != null
        ? updateZone(selectedTenantId.value, payload.id, payload.data as ZoneUpdatePayload)
        : createZone(selectedTenantId.value, payload.data),
    onSuccess: () => {
      editingZone.value = null;
      creatingZone.value = false;
      loadHierarchy();
      loadZoneOverlay();
      invalidate();
    },
  });

  // loadZones: invalidate to force a fresh fetch (also usable as a manual refresh)
  function loadZones(): void {
    queryClient.invalidateQueries({ queryKey: ['tenant', selectedTenantId.value, 'zones'] });
  }

  function deleteZone(id: number): void {
    deleteMutation.mutate(id);
  }

  function saveZone(payload: Record<string, unknown>): void {
    saveMutation.mutate({
      isEdit: !!editingZone.value,
      id: editingZone.value?.id,
      data: payload as unknown as ZoneCreatePayload,
    });
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

  // Watch tenant changes to reset UI state (TanStack handles re-fetch via computed queryKey)
  if (!watcherRegistered) {
    watcherRegistered = true;
    watch(selectedTenantId, () => {
      editingZone.value = null;
      creatingZone.value = false;
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
