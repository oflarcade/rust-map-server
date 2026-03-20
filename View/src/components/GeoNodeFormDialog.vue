<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import Button from 'primevue/button';
import { useGeoHierarchyEditor, type GeoNode, type GeoLevel } from '../composables/useGeoHierarchyEditor';

const props = defineProps<{
  statePcode: string;
  parentNode: GeoNode | null;  // null = root under state
  editNode?: GeoNode | null;   // when editing existing node
}>();

const emit = defineEmits<{
  (e: 'close'): void;
}>();

const { geoLevels, createNode, updateNode } = useGeoHierarchyEditor();

const name    = ref('');
const color   = ref('#3b82f6');
const levelId = ref<number | null>(null);
const error   = ref('');
const saving  = ref(false);

// When editing, populate form
watch(() => props.editNode, (node) => {
  if (node) {
    name.value    = node.name;
    color.value   = node.color ?? '#3b82f6';
    levelId.value = node.level_id;
  } else {
    name.value    = '';
    color.value   = '#3b82f6';
    levelId.value = null;
  }
}, { immediate: true });

// Filter eligible levels: only levels deeper than the parent's level
const eligibleLevels = computed<GeoLevel[]>(() => {
  if (!geoLevels.value.length) return [];
  if (props.parentNode?.level_order != null) {
    return geoLevels.value.filter(l => l.level_order > props.parentNode!.level_order!);
  }
  // Root node: any level, but pick first
  return geoLevels.value;
});

// Auto-select first eligible level when levels load
watch(eligibleLevels, (levels) => {
  if (levelId.value == null && levels.length > 0) {
    levelId.value = levels[0].id;
  }
}, { immediate: true });

const parentLabel = computed(() => {
  if (props.parentNode) return `${props.parentNode.name} (${props.parentNode.pcode})`;
  return props.statePcode;
});

async function save() {
  error.value = '';
  if (!name.value.trim()) { error.value = 'Name is required.'; return; }
  if (!levelId.value) { error.value = 'Level is required.'; return; }

  saving.value = true;
  try {
    if (props.editNode) {
      await updateNode(props.editNode.id, {
        name:  name.value.trim(),
        color: color.value,
      });
    } else {
      await createNode({
        state_pcode: props.statePcode,
        parent_id:   props.parentNode?.id ?? null,
        level_id:    levelId.value,
        name:        name.value.trim(),
        color:       color.value,
      });
    }
    emit('close');
  } catch (e: any) {
    error.value = e.message ?? 'Save failed.';
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50" @click.self="emit('close')">
    <div class="bg-white rounded-xl shadow-2xl w-80 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <h3 class="font-semibold text-slate-800 text-sm">
          {{ editNode ? 'Edit Node' : 'New Node' }}
        </h3>
        <button class="text-slate-400 hover:text-slate-700" @click="emit('close')">
          <i class="pi pi-times" />
        </button>
      </div>

      <div class="text-xs text-slate-500">
        Under: <span class="font-medium text-slate-700">{{ parentLabel }}</span>
      </div>

      <div class="space-y-3">
        <!-- Level selector (hidden when editing) -->
        <div v-if="!editNode">
          <label class="block text-xs font-medium text-slate-600 mb-1">Level</label>
          <div v-if="eligibleLevels.length === 0" class="text-xs text-amber-600 italic">
            No eligible levels. Define levels first.
          </div>
          <select
            v-else
            v-model.number="levelId"
            class="w-full border border-slate-300 rounded px-2 py-1.5 text-sm"
          >
            <option v-for="l in eligibleLevels" :key="l.id" :value="l.id">
              {{ l.level_label }} ({{ l.level_code }})
            </option>
          </select>
        </div>

        <!-- Name -->
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Name</label>
          <input
            v-model="name"
            placeholder="e.g. Jigawa North East"
            class="w-full border border-slate-300 rounded px-2 py-1.5 text-sm"
            @keydown.enter="save"
          />
        </div>

        <!-- Color -->
        <div class="flex items-center gap-3">
          <label class="text-xs font-medium text-slate-600">Color</label>
          <input v-model="color" type="color" class="h-7 w-14 border border-slate-200 rounded cursor-pointer" />
          <span class="text-xs font-mono text-slate-500">{{ color }}</span>
        </div>
      </div>

      <div v-if="error" class="text-xs text-red-600 bg-red-50 rounded px-2 py-1">{{ error }}</div>

      <div class="flex gap-2 pt-1">
        <Button label="Save" :loading="saving" class="flex-1" @click="save" />
        <Button label="Cancel" severity="secondary" outlined class="flex-1" @click="emit('close')" />
      </div>
    </div>
  </div>
</template>
