<script setup lang="ts">
import { computed, onMounted } from 'vue';
import { useZoneManager } from '../composables/useZoneManager';
import { useTileInspector } from '../composables/useTileInspector';
import ZoneRow from './ZoneRow.vue';
import ZoneForm from './ZoneForm.vue';
import TerritoriesDrawer from './TerritoriesDrawer.vue';

const { zones, loadingZones, editingZone, creatingZone, loadZones, saveZone, deleteZone, startEdit, startCreate, cancelForm } = useZoneManager();
const { currentTenant, boundaryHierarchy } = useTileInspector();

const hierarchyStates = computed(() => boundaryHierarchy.value?.states ?? []);

onMounted(() => loadZones());
</script>

<template>
  <div class="zone-section">
    <div class="section-header">
      <span class="section-title">Zones</span>
      <span v-if="loadingZones" class="loading-dot">…</span>
      <span class="zone-count" v-else>{{ zones.length }}</span>
      <button class="add-zone-btn" @click="startCreate" :class="{ active: creatingZone && !editingZone }">
        + New
      </button>
    </div>

    <!-- Inline create form -->
    <Transition name="slide-form">
      <ZoneForm
        v-if="creatingZone && !editingZone"
        :edit-zone="null"
        :hierarchy-states="hierarchyStates"
        :zone-types="currentTenant.zoneTypes"
        :existing-zones="zones"
        @save="(p) => saveZone(p)"
        @cancel="cancelForm"
      />
    </Transition>

    <!-- Zone list -->
    <div class="zone-list" v-if="zones.length > 0">
      <template v-for="zone in zones" :key="zone.id">
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
            :existing-zones="zones"
            @save="(p) => saveZone(p)"
            @cancel="cancelForm"
          />
        </Transition>
      </template>
    </div>

    <div v-else-if="!loadingZones && !creatingZone" class="empty-zones">
      No zones yet. Click "+ New" to create one.
    </div>

    <TerritoriesDrawer />
  </div>
</template>

<style scoped>
.zone-section { display: flex; flex-direction: column; gap: 6px; }

.section-header {
  display: flex; align-items: center; gap: 6px;
  padding-bottom: 6px; border-bottom: 1px solid #e2e8f0;
}
.section-title { font-size: 13px; font-weight: 700; color: #0f172a; }
.loading-dot { font-size: 12px; color: #94a3b8; }
.zone-count {
  background: #f1f5f9; color: #64748b;
  font-size: 11px; padding: 1px 6px; border-radius: 10px; font-weight: 600;
}

.add-zone-btn {
  margin-left: auto;
  background: #eff6ff; color: #3b82f6; border: 1px solid #bfdbfe;
  border-radius: 5px; padding: 3px 10px; font-size: 12px; cursor: pointer;
  font-weight: 600; transition: background 0.1s;
}
.add-zone-btn:hover, .add-zone-btn.active { background: #dbeafe; }

.zone-list { display: flex; flex-direction: column; gap: 4px; }
.empty-zones { font-size: 12px; color: #94a3b8; text-align: center; padding: 8px 0; }

.slide-form-enter-active, .slide-form-leave-active { transition: all 0.2s ease; overflow: hidden; }
.slide-form-enter-from, .slide-form-leave-to { opacity: 0; transform: translateY(-6px); max-height: 0; }
.slide-form-enter-to, .slide-form-leave-from { opacity: 1; max-height: 600px; }
</style>
