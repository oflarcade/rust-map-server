<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import Button from 'primevue/button';
import { useGeoHierarchyEditor, type GeoNode, type GeoLevel } from '../composables/useGeoHierarchyEditor';
import { labelToCode } from '../api/geoHierarchy';

const props = defineProps<{
  statePcode: string;
  parentNode: GeoNode | null;   // null = root under state
  editNode?: GeoNode | null;    // when editing existing node
}>();

const emit = defineEmits<{ (e: 'close'): void }>();

const { geoLevels, hdxLevelLabels, createLevel, createNode, updateNode } = useGeoHierarchyEditor();

const levelTypeInput = ref('');
const nodeName       = ref('');
const color          = ref('#3b82f6');
const error          = ref('');
const saving         = ref(false);

// Auto-generated code preview (read-only)
const autoCode = computed(() => labelToCode(levelTypeInput.value));

// All known level type options (hdx canonical + already-defined on this tenant)
const levelTypeOptions = computed(() => {
  const fromHdx = hdxLevelLabels.value ?? [];
  const fromTenant = geoLevels.value.map(l => l.level_label);
  return [...new Set([...fromHdx, ...fromTenant])].sort((a, b) => a.localeCompare(b));
});

// Depth-aware label for the parent row
const parentLabel = computed(() => {
  if (props.parentNode) return `${props.parentNode.name} (${props.parentNode.pcode})`;
  return props.statePcode;
});

watch(() => props.editNode, (node) => {
  error.value = '';
  if (node) {
    nodeName.value      = node.name;
    color.value         = node.color ?? '#3b82f6';
    levelTypeInput.value = node.level_label ?? '';
  } else {
    nodeName.value       = '';
    color.value          = '#3b82f6';
    levelTypeInput.value = '';
  }
}, { immediate: true });

/** Find or create the geo_hierarchy_level for this label. */
async function resolveLevel(): Promise<GeoLevel> {
  const label = levelTypeInput.value.trim();
  const existing = geoLevels.value.find(
    l => l.level_label.toLowerCase() === label.toLowerCase(),
  );
  if (existing) return existing;

  // New level — order is next after all existing
  const nextOrder = geoLevels.value.length > 0
    ? Math.max(...geoLevels.value.map(l => l.level_order)) + 1
    : 1;

  return createLevel({
    level_order: nextOrder,
    level_label: label,
    level_code:  autoCode.value,
  });
}

async function save() {
  error.value = '';
  if (!nodeName.value.trim()) { error.value = 'Group name is required.'; return; }
  if (!props.editNode && !levelTypeInput.value.trim()) { error.value = 'Level type is required.'; return; }

  saving.value = true;
  try {
    if (props.editNode) {
      await updateNode(props.editNode.id, { name: nodeName.value.trim(), color: color.value });
    } else {
      const level = await resolveLevel();
      await createNode({
        state_pcode: props.statePcode,
        parent_id:   props.parentNode?.id ?? null,
        level_id:    level.id,
        name:        nodeName.value.trim(),
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
  <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4" @click.self="emit('close')">
    <div class="bg-white rounded-xl shadow-2xl w-full max-w-sm flex flex-col p-5 shadow-[0_20px_50px_rgba(0,0,0,0.18)]">

      <!-- Header -->
      <div class="flex items-center justify-between mb-1">
        <h3 class="font-semibold text-slate-800 text-sm">
          {{ editNode ? 'Edit group' : 'Add level' }}
        </h3>
        <button type="button" class="text-slate-400 hover:text-slate-700 rounded focus:outline-none" @click="emit('close')">
          <i class="pi pi-times" />
        </button>
      </div>

      <div class="text-xs text-slate-500 mb-4">
        Under: <span class="font-medium text-slate-700">{{ parentLabel }}</span>
      </div>

      <div class="space-y-3">
        <!-- Level type (hidden when editing) -->
        <div v-if="!editNode">
          <label class="block text-xs font-medium text-slate-600 mb-1">Level type</label>
          <input
            v-model="levelTypeInput"
            list="level-type-options"
            placeholder="Select or type a level type…"
            class="w-full border border-slate-300 rounded px-2 py-1.5 text-sm"
            @keydown.enter="save"
          />
          <datalist id="level-type-options">
            <option v-for="opt in levelTypeOptions" :key="opt" :value="opt" />
          </datalist>
          <!-- Auto-generated code preview -->
          <div v-if="levelTypeInput.trim()" class="mt-1 flex items-center gap-1.5 text-[10px] text-slate-400">
            <span>Auto code:</span>
            <span class="font-mono font-semibold text-indigo-500">{{ autoCode }}</span>
            <span>·</span>
            <span>adm{{ (parentNode?.level_order ?? 0) + 2 }}</span>
          </div>
        </div>

        <!-- Group name -->
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">
            {{ editNode ? 'Name' : 'Group name' }}
          </label>
          <input
            v-model="nodeName"
            placeholder="e.g. Jigawa North East"
            class="w-full border border-slate-300 rounded px-2 py-1.5 text-sm"
            @keydown.enter="save"
          />
        </div>

        <!-- Color -->
        <div class="flex items-center gap-3">
          <label class="text-xs font-medium text-slate-600">Color</label>
          <input v-model="color" type="color" class="h-7 w-14 border border-slate-200 rounded cursor-pointer" />
          <span class="text-xs font-mono text-slate-400">{{ color }}</span>
        </div>

        <div v-if="error" class="text-xs text-red-600 bg-red-50 rounded px-2 py-1">{{ error }}</div>
      </div>

      <div class="flex gap-2 pt-4 border-t border-slate-100 mt-4">
        <Button label="Save" :loading="saving" class="flex-1" @click="save" />
        <Button label="Cancel" severity="secondary" outlined class="flex-1" @click="emit('close')" />
      </div>
    </div>
  </div>
</template>
