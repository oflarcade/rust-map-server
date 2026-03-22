<script setup lang="ts">
import { ref, computed } from 'vue';
import Button from 'primevue/button';
import GeoLevelFormDialog from './GeoLevelFormDialog.vue';
import { useGeoHierarchyEditor, type GeoLevel } from '../composables/useGeoHierarchyEditor';

const {
  geoLevels,
  levelsLoading,
  deleteLevel,
} = useGeoHierarchyEditor();

const showForm = ref(false);
const editingId = ref<number | null>(null);

const editLevelForDialog = computed(() => {
  if (editingId.value == null) return null;
  return geoLevels.value.find(l => l.id === editingId.value) ?? null;
});

function openCreate() {
  editingId.value = null;
  showForm.value = true;
}

function openEdit(level: GeoLevel) {
  editingId.value = level.id;
  showForm.value = true;
}

function cancelForm() {
  showForm.value = false;
}

async function removeLevel(level: GeoLevel) {
  if (!confirm(`Delete level "${level.level_label}"?\n\nAll nodes at this level will also be deleted.`)) return;
  await deleteLevel(level.id).catch(() => {});
}
</script>

<template>
  <div class="bg-slate-50/90 border border-slate-200/90 rounded-lg p-2">
    <div class="flex items-center justify-between mb-1.5">
      <span class="text-[10px] font-semibold text-slate-500 uppercase tracking-wider">Levels</span>
      <Button
        label="+ Level"
        size="small"
        severity="secondary"
        outlined
        class="!text-xs !py-0.5 !px-2"
        @click="openCreate"
      />
    </div>

    <div v-if="levelsLoading" class="text-xs text-slate-400">Loading…</div>
    <div v-else-if="geoLevels.length === 0" class="text-xs text-slate-400 italic">
      No levels defined. Add levels before creating nodes.
    </div>
    <div v-else class="flex flex-wrap gap-1.5">
      <div
        v-for="level in geoLevels"
        :key="level.id"
        class="flex items-center gap-1 bg-slate-100 rounded px-2 py-0.5 text-xs"
      >
        <span class="font-mono font-semibold text-indigo-700">{{ level.level_code }}</span>
        <span class="text-slate-600">{{ level.level_label }}</span>
        <button
          class="ml-0.5 text-slate-400 hover:text-slate-700"
          title="Edit"
          @click="openEdit(level)"
        >
          <i class="pi pi-pencil text-[10px]" />
        </button>
        <button
          class="text-slate-400 hover:text-red-500"
          title="Delete"
          @click="removeLevel(level)"
        >
          <i class="pi pi-times text-[10px]" />
        </button>
      </div>
    </div>

    <GeoLevelFormDialog
      v-if="showForm"
      :edit-level="editLevelForDialog"
      @close="cancelForm"
    />
  </div>
</template>
