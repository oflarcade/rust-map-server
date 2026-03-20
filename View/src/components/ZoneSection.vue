<script setup lang="ts">
import { computed, onMounted } from 'vue';
import Badge from 'primevue/badge';
import Button from 'primevue/button';
import { useZoneManager } from '../composables/useZoneManager';
import { useTileInspector } from '../composables/useTileInspector';
import { useBoundarySearch } from '../composables/useBoundarySearch';
import ZoneRow from './ZoneRow.vue';
import ZoneForm from './ZoneForm.vue';
import TerritoriesDrawer from './TerritoriesDrawer.vue';

const { zones, loadingZones, editingZone, creatingZone, loadZones, saveZone, deleteZone, startEdit, startCreate, cancelForm } = useZoneManager();
const { currentTenant } = useTileInspector();
const { boundaryHierarchy } = useBoundarySearch();

const hierarchyStates = computed(() => boundaryHierarchy.value?.states ?? []);
const safeZones = computed(() => zones.value ?? []);

onMounted(() => loadZones());
</script>

<template>
  <div class="flex flex-col gap-1.5">
    <div class="flex items-center gap-1.5 pb-1.5 border-b border-slate-200">
      <span class="text-xs font-bold text-slate-900">Zones</span>
      <span v-if="loadingZones" class="text-xs text-slate-400">…</span>
      <Badge v-else :value="safeZones.length" severity="secondary" />
      <Button
        label="+ New"
        size="small"
        variant="outlined"
        class="ml-auto"
        :class="{ '!border-blue-400': creatingZone && !editingZone }"
        @click="startCreate"
      />
    </div>

    <!-- Inline create form -->
    <Transition name="slide-form">
      <ZoneForm
        v-if="creatingZone && !editingZone"
        :edit-zone="null"
        :hierarchy-states="hierarchyStates"
        :zone-types="currentTenant.zoneTypes"
        :existing-zones="safeZones"
        @save="(p) => saveZone(p)"
        @cancel="cancelForm"
      />
    </Transition>

    <!-- Zone list -->
    <div class="flex flex-col gap-1" v-if="safeZones.length > 0">
      <template v-for="zone in safeZones" :key="zone.id">
        <ZoneRow
          :zone="zone"
          :selected="editingZone?.id === zone.id"
          @edit="startEdit"
          @delete="deleteZone"
        />
        <!-- Inline edit form expands below the row -->
        <Transition name="slide-form">
          <ZoneForm
            v-if="editingZone?.id === zone.id"
            :edit-zone="editingZone"
            :hierarchy-states="hierarchyStates"
            :zone-types="currentTenant.zoneTypes"
            :existing-zones="safeZones"
            @save="(p) => saveZone(p)"
            @cancel="cancelForm"
          />
        </Transition>
      </template>
    </div>

    <div v-else-if="!loadingZones && !creatingZone" class="text-xs text-slate-400 text-center py-2">
      No zones yet. Click "+ New" to create one.
    </div>

    <TerritoriesDrawer />
  </div>
</template>

<style scoped>
.slide-form-enter-active,
.slide-form-leave-active {
  transition: all 0.2s ease;
  overflow: hidden;
}
.slide-form-enter-from,
.slide-form-leave-to {
  opacity: 0;
  transform: translateY(-6px);
  max-height: 0;
}
.slide-form-enter-to,
.slide-form-leave-from {
  opacity: 1;
  max-height: 600px;
}
</style>
