<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import type { Zone } from '../composables/useZoneManager';
import type { HierarchyState } from '../composables/useTileInspector';
import InputText from 'primevue/inputtext';
import ColorPicker from 'primevue/colorpicker';
import RadioButton from 'primevue/radiobutton';
import Select from 'primevue/select';
import Checkbox from 'primevue/checkbox';
import Button from 'primevue/button';
import { useToast } from 'primevue/usetoast';

const toast = useToast();

const props = defineProps<{
  editZone: Zone | null;
  hierarchyStates: HierarchyState[];
  zoneTypes?: string[];
  existingZones: Zone[];
}>();

const emit = defineEmits<{
  (e: 'save', payload: Record<string, unknown>): void;
  (e: 'cancel'): void;
}>();

const DEFAULT_COLORS = ['#3b82f6', '#10b981', '#f59e0b', '#8b5cf6', '#ef4444', '#ec4899', '#06b6d4'];

const name = ref('');
const typeLabel = ref('');
const color = ref('#3b82f6');
// ColorPicker uses hex WITHOUT '#'
const colorHex = computed({
  get: () => color.value.replace('#', ''),
  set: (v: string) => { color.value = '#' + v; },
});
const parentPcode = ref<string | null>(null);
const selectedPcodes = ref<string[]>([]);
const childrenType = ref<'lga' | 'zone'>('lga');
const isEditing = computed(() => !!props.editZone);

watch(() => props.editZone, (z) => {
  if (z) {
    name.value = z.zone_name;
    typeLabel.value = z.zone_type_label ?? '';
    color.value = z.color ?? '#3b82f6';
    parentPcode.value = z.parent_pcode ?? null;
    selectedPcodes.value = z.constituent_pcodes ?? [];
    childrenType.value = z.children_type ?? 'lga';
  } else {
    name.value = '';
    typeLabel.value = '';
    color.value = DEFAULT_COLORS[0];
    parentPcode.value = null;
    selectedPcodes.value = [];
    childrenType.value = 'lga';
  }
}, { immediate: true });

const parentOptions = computed(() =>
  props.hierarchyStates.map((s) => ({ pcode: s.pcode, name: s.name }))
);

const childOptions = computed(() => {
  if (childrenType.value === 'zone') {
    return props.existingZones.map((z) => ({ pcode: z.zone_pcode, name: z.zone_name }));
  }
  const parent = parentPcode.value;
  if (!parent) {
    return props.hierarchyStates.flatMap((s) => s.lgas ?? []);
  }
  const state = props.hierarchyStates.find((s) => s.pcode === parent);
  return state ? (state.lgas ?? []) : [];
});

function selectAll() {
  selectedPcodes.value = childOptions.value.map((c) => c.pcode);
}
function clearAll() {
  selectedPcodes.value = [];
}

async function submit() {
  if (!name.value.trim()) return;
  const payload: Record<string, unknown> = {
    zone_name: name.value.trim(),
    zone_type_label: typeLabel.value.trim() || null,
    color: color.value,
    constituent_pcodes: selectedPcodes.value,
    children_type: childrenType.value,
  };
  if (parentPcode.value) payload.parent_pcode = parentPcode.value;
  try {
    emit('save', payload);
    toast.add({ severity: 'success', summary: 'Zone saved', life: 3000 });
  } catch (err: any) {
    toast.add({ severity: 'error', summary: 'Failed to save', detail: err.message, life: 4000 });
  }
}
</script>

<template>
  <div class="flex flex-col gap-3 bg-slate-50 border border-slate-200 rounded-lg p-3">

    <!-- Name -->
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-slate-500 uppercase tracking-wide">Name</label>
      <InputText v-model="name" placeholder="Zone name" class="w-full" />
    </div>

    <!-- Type label -->
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-slate-500 uppercase tracking-wide">Type label</label>
      <Select
        v-if="zoneTypes?.length"
        v-model="typeLabel"
        :options="zoneTypes"
        showClear
        placeholder="— none —"
        class="w-full"
      />
      <InputText v-else v-model="typeLabel" placeholder="e.g. Cluster" class="w-full" />
    </div>

    <!-- Color -->
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-slate-500 uppercase tracking-wide">Color</label>
      <div class="flex items-center gap-2 flex-wrap">
        <span
          v-for="c in DEFAULT_COLORS" :key="c"
          class="w-[18px] h-[18px] rounded cursor-pointer border-2 transition-transform hover:scale-110"
          :style="{ background: c, borderColor: color === c ? '#0f172a' : 'transparent' }"
          @click="color = c"
        ></span>
        <ColorPicker v-model="colorHex" format="hex" />
      </div>
    </div>

    <!-- Parent state -->
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-slate-500 uppercase tracking-wide">Parent state</label>
      <Select
        v-model="parentPcode"
        :options="parentOptions"
        optionValue="pcode"
        optionLabel="name"
        showClear
        placeholder="— all states —"
        class="w-full"
      />
    </div>

    <!-- Members type -->
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-slate-500 uppercase tracking-wide">Members</label>
      <div class="flex gap-4">
        <div class="flex items-center gap-2">
          <RadioButton v-model="childrenType" inputId="ct-lga" value="lga" />
          <label for="ct-lga" class="text-sm text-slate-600 cursor-pointer">LGAs</label>
        </div>
        <div class="flex items-center gap-2">
          <RadioButton v-model="childrenType" inputId="ct-zone" value="zone" />
          <label for="ct-zone" class="text-sm text-slate-600 cursor-pointer">Child zones</label>
        </div>
      </div>
    </div>

    <!-- Member list -->
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-2">
        <Button label="All" size="small" variant="text" @click="selectAll()" />
        <Button label="Clear" size="small" variant="text" @click="clearAll()" />
        <span class="text-[11px] text-slate-400 ml-auto">{{ selectedPcodes.length }} selected</span>
      </div>
      <div class="max-h-[150px] overflow-y-auto border border-slate-200 rounded-md bg-white">
        <label
          v-for="child in childOptions" :key="child.pcode"
          class="flex items-center gap-2 px-2 py-1 text-xs text-slate-700 cursor-pointer hover:bg-slate-50 transition-colors"
          :class="{ 'bg-blue-50': selectedPcodes.includes(child.pcode) }"
          :for="child.pcode"
        >
          <Checkbox v-model="selectedPcodes" :value="child.pcode" :inputId="child.pcode" />
          <span>{{ child.name }}</span>
        </label>
        <div v-if="childOptions.length === 0" class="px-2 py-2 text-xs text-slate-400 text-center">
          No members available
        </div>
      </div>
    </div>

    <!-- Actions -->
    <div class="flex gap-2 mt-1">
      <Button
        :label="isEditing ? 'Save Changes' : 'Create Zone'"
        icon="pi pi-check"
        class="w-full"
        :disabled="!name.trim()"
        @click="submit()"
      />
      <Button
        label="Cancel"
        variant="outlined"
        severity="secondary"
        class="w-full"
        @click="$emit('cancel')"
      />
    </div>

  </div>
</template>
