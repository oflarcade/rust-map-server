<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import Button from 'primevue/button';
import { useGeoHierarchyEditor, type GeoLevel } from '../composables/useGeoHierarchyEditor';

const props = defineProps<{
  editLevel: GeoLevel | null;
}>();

const emit = defineEmits<{
  (e: 'close'): void;
}>();

const {
  geoLevels,
  hdxLevelLabels,
  hdxLabelsLoading,
  createLevel,
  updateLevel,
} = useGeoHierarchyEditor();

const formOrder = ref(1);
const formLabel = ref('');
const formCode = ref('');
const formError = ref('');
const saving = ref(false);

const labelChoices = computed(() => {
  const fromApi = [...(hdxLevelLabels.value ?? [])];
  const cur = formLabel.value.trim();
  if (cur && !fromApi.includes(cur)) fromApi.push(cur);
  return fromApi.sort((a, b) => a.localeCompare(b));
});

function defaultOrder() {
  return geoLevels.value.length > 0
    ? Math.max(...geoLevels.value.map(l => l.level_order)) + 1
    : 1;
}

watch(
  () => props.editLevel,
  (lvl) => {
    formError.value = '';
    if (lvl) {
      formOrder.value = lvl.level_order;
      formLabel.value = lvl.level_label;
      formCode.value = lvl.level_code;
    } else {
      formOrder.value = defaultOrder();
      formLabel.value = '';
      formCode.value = '';
    }
  },
  { immediate: true },
);

async function saveForm() {
  formError.value = '';
  if (!formLabel.value.trim() || !formCode.value.trim()) {
    formError.value = 'Level type and short code are required.';
    return;
  }
  saving.value = true;
  try {
    if (props.editLevel) {
      await updateLevel(props.editLevel.id, {
        level_order: formOrder.value,
        level_label: formLabel.value.trim(),
        level_code: formCode.value.trim().toUpperCase(),
      });
    } else {
      await createLevel({
        level_order: formOrder.value,
        level_label: formLabel.value.trim(),
        level_code: formCode.value.trim().toUpperCase(),
      });
    }
    emit('close');
  } catch (e: any) {
    formError.value = e.message ?? 'Save failed.';
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4" @click.self="emit('close')">
    <div
      class="bg-white rounded-xl shadow-2xl w-full max-w-md max-h-[min(90vh,560px)] flex flex-col p-5 shadow-[0_20px_50px_rgba(0,0,0,0.18)]"
    >
      <div class="flex items-center justify-between flex-shrink-0">
        <h3 class="font-semibold text-slate-800 text-sm">
          {{ editLevel ? 'Edit level' : 'New level' }}
        </h3>
        <button
          type="button"
          class="text-slate-400 hover:text-slate-700 focus:outline-none focus-visible:ring-2 rounded"
          @click="emit('close')"
        >
          <i class="pi pi-times" />
        </button>
      </div>

      <div class="space-y-3 mt-4 flex-1 min-h-0 overflow-y-auto overscroll-contain">
        <div class="grid grid-cols-3 gap-2">
          <div>
            <label class="block text-[10px] text-slate-500 mb-0.5">Order</label>
            <input
              v-model.number="formOrder"
              type="number"
              min="1"
              class="w-full border border-slate-300 rounded px-2 py-1 text-xs"
            />
          </div>
          <div class="col-span-2">
            <label class="block text-[10px] text-slate-500 mb-0.5">Code</label>
            <input
              v-model="formCode"
              placeholder="SD"
              maxlength="10"
              class="w-full border border-slate-300 rounded px-2 py-1 text-xs uppercase"
            />
          </div>
          <div class="col-span-3">
            <label class="block text-[10px] text-slate-500 mb-0.5">Admin level type</label>
            <template v-if="hdxLabelsLoading">
              <div class="text-xs text-slate-400 py-1">Loading types…</div>
            </template>
            <template v-else-if="labelChoices.length === 0">
              <div class="text-[10px] text-amber-700 leading-snug">
                No level types available for this tenant’s country. Check API
                <code class="text-[9px]">/admin/geo-hierarchy/level-labels</code>.
              </div>
            </template>
            <select
              v-else
              v-model="formLabel"
              class="w-full border border-slate-300 rounded px-2 py-1.5 text-xs bg-white"
            >
              <option disabled value="">Select type…</option>
              <option v-for="lbl in labelChoices" :key="lbl" :value="lbl">
                {{ lbl }}
              </option>
            </select>
          </div>
        </div>
        <div v-if="formError" class="text-xs text-red-600">{{ formError }}</div>
      </div>

      <div class="flex gap-2 pt-4 flex-shrink-0 border-t border-slate-100">
        <Button label="Save" size="small" class="flex-1" :loading="saving" :disabled="!formLabel.trim()" @click="saveForm" />
        <Button label="Cancel" size="small" severity="secondary" outlined class="flex-1" @click="emit('close')" />
      </div>
    </div>
  </div>
</template>
