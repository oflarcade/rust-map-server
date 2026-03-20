<script setup lang="ts">
import { ref, computed } from 'vue';
import Button from 'primevue/button';
import { useGeoHierarchyEditor, type GeoLevel } from '../composables/useGeoHierarchyEditor';

const {
  geoLevels,
  hdxLevelLabels,
  levelsLoading,
  hdxLabelsLoading,
  createLevel,
  updateLevel,
  deleteLevel,
} = useGeoHierarchyEditor();

// Form state
const showForm   = ref(false);
const editingId  = ref<number | null>(null);
const formOrder  = ref<number>(1);
const formLabel  = ref('');
const formCode   = ref('');
const formError  = ref('');
const saving     = ref(false);

/** HDX labels from DB, plus current value when editing a legacy / migrated row. */
const labelChoices = computed(() => {
  const fromApi = [...(hdxLevelLabels.value ?? [])];
  const cur = formLabel.value.trim();
  if (cur && !fromApi.includes(cur)) fromApi.push(cur);
  return fromApi.sort((a, b) => a.localeCompare(b));
});

function openCreate() {
  editingId.value = null;
  formOrder.value = (geoLevels.value.length > 0
    ? Math.max(...geoLevels.value.map(l => l.level_order)) + 1
    : 1);
  formLabel.value = '';
  formCode.value  = '';
  formError.value = '';
  showForm.value  = true;
}

function openEdit(level: GeoLevel) {
  editingId.value = level.id;
  formOrder.value = level.level_order;
  formLabel.value = level.level_label;
  formCode.value  = level.level_code;
  formError.value = '';
  showForm.value  = true;
}

function cancelForm() {
  showForm.value = false;
}

async function saveForm() {
  formError.value = '';
  if (!formLabel.value.trim() || !formCode.value.trim()) {
    formError.value = 'HDX level type and short code are required.';
    return;
  }
  saving.value = true;
  try {
    if (editingId.value != null) {
      await updateLevel(editingId.value, {
        level_order: formOrder.value,
        level_label: formLabel.value.trim(),
        level_code:  formCode.value.trim().toUpperCase(),
      });
    } else {
      await createLevel({
        level_order: formOrder.value,
        level_label: formLabel.value.trim(),
        level_code:  formCode.value.trim().toUpperCase(),
      });
    }
    showForm.value = false;
  } catch (e: any) {
    formError.value = e.message ?? 'Save failed.';
  } finally {
    saving.value = false;
  }
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

    <!-- Inline form -->
    <div v-if="showForm" class="mt-3 border-t border-slate-200 pt-3 space-y-2">
      <div class="grid grid-cols-3 gap-2">
        <div>
          <label class="block text-[10px] text-slate-500 mb-0.5">Order</label>
          <input
            v-model.number="formOrder"
            type="number" min="1"
            class="w-full border border-slate-300 rounded px-2 py-1 text-xs"
          />
        </div>
        <div>
          <label class="block text-[10px] text-slate-500 mb-0.5">Code</label>
          <input
            v-model="formCode"
            placeholder="SD"
            maxlength="10"
            class="w-full border border-slate-300 rounded px-2 py-1 text-xs uppercase"
          />
        </div>
        <div class="col-span-3 -mt-1">
          <label class="block text-[10px] text-slate-500 mb-0.5">HDX level type</label>
          <template v-if="hdxLabelsLoading">
            <div class="text-xs text-slate-400 py-1">Loading types…</div>
          </template>
          <template v-else-if="labelChoices.length === 0">
            <div class="text-[10px] text-amber-700 leading-snug">
              No <code class="text-[9px]">level_label</code> values in PostGIS for this tenant’s country (adm3+).
              Run HDX / INEC import so boundaries carry official type names.
            </div>
          </template>
          <select
            v-else
            v-model="formLabel"
            class="w-full border border-slate-300 rounded px-2 py-1.5 text-xs bg-white"
          >
            <option disabled value="">Select type (from adm_features)…</option>
            <option v-for="lbl in labelChoices" :key="lbl" :value="lbl">
              {{ lbl }}
            </option>
          </select>
        </div>
      </div>
      <div v-if="formError" class="text-xs text-red-600">{{ formError }}</div>
      <div class="flex gap-2">
        <Button label="Save" size="small" :loading="saving" :disabled="!formLabel.trim()" @click="saveForm" />
        <Button label="Cancel" size="small" severity="secondary" outlined @click="cancelForm" />
      </div>
    </div>
  </div>
</template>
