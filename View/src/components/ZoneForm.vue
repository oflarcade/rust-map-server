<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import type { Zone } from '../composables/useZoneManager';
import type { HierarchyState } from '../composables/useTileInspector';

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
const parentPcode = ref('');
const selectedPcodes = ref<Set<string>>(new Set());
const childrenType = ref<'lga' | 'zone'>('lga');

watch(() => props.editZone, (z) => {
  if (z) {
    name.value = z.zone_name;
    typeLabel.value = z.zone_type_label ?? '';
    color.value = z.color ?? '#3b82f6';
    parentPcode.value = z.parent_pcode ?? '';
    selectedPcodes.value = new Set(z.constituent_pcodes ?? []);
    childrenType.value = z.children_type ?? 'lga';
  } else {
    name.value = '';
    typeLabel.value = '';
    color.value = DEFAULT_COLORS[0];
    parentPcode.value = '';
    selectedPcodes.value = new Set();
    childrenType.value = 'lga';
  }
}, { immediate: true });

const parentStateOptions = computed(() => props.hierarchyStates);

const childOptions = computed(() => {
  if (childrenType.value === 'zone') {
    return props.existingZones.map((z) => ({ pcode: z.zone_pcode, name: z.zone_name }));
  }
  // LGA mode: show LGAs of the selected parent state (or all if no parent)
  const parent = parentPcode.value;
  if (!parent) {
    return props.hierarchyStates.flatMap((s) => s.lgas ?? []);
  }
  const state = props.hierarchyStates.find((s) => s.pcode === parent);
  return state ? (state.lgas ?? []) : [];
});

function togglePcode(pcode: string) {
  const next = new Set(selectedPcodes.value);
  if (next.has(pcode)) next.delete(pcode); else next.add(pcode);
  selectedPcodes.value = next;
}

function selectAll() {
  selectedPcodes.value = new Set(childOptions.value.map((c) => c.pcode));
}
function clearAll() {
  selectedPcodes.value = new Set();
}

function submit() {
  if (!name.value.trim()) return;
  const payload: Record<string, unknown> = {
    zone_name: name.value.trim(),
    zone_type_label: typeLabel.value.trim() || null,
    color: color.value,
    constituent_pcodes: Array.from(selectedPcodes.value),
    children_type: childrenType.value,
  };
  if (parentPcode.value) payload.parent_pcode = parentPcode.value;
  emit('save', payload);
}
</script>

<template>
  <div class="zone-form">
    <div class="form-row">
      <label>Name</label>
      <input v-model="name" placeholder="Zone name" class="form-input" />
    </div>

    <div class="form-row">
      <label>Type label</label>
      <div class="type-row">
        <select v-if="zoneTypes?.length" v-model="typeLabel" class="form-input">
          <option value="">— none —</option>
          <option v-for="t in zoneTypes" :key="t" :value="t">{{ t }}</option>
        </select>
        <input v-else v-model="typeLabel" placeholder="e.g. Cluster" class="form-input" />
      </div>
    </div>

    <div class="form-row">
      <label>Color</label>
      <div class="color-row">
        <span
          v-for="c in DEFAULT_COLORS" :key="c"
          class="color-swatch" :style="{ background: c }"
          :class="{ active: color === c }"
          @click="color = c"
        ></span>
        <input type="color" v-model="color" class="color-picker" title="Custom color" />
      </div>
    </div>

    <div class="form-row">
      <label>Parent state</label>
      <select v-model="parentPcode" class="form-input">
        <option value="">— all states —</option>
        <option v-for="s in parentStateOptions" :key="s.pcode" :value="s.pcode">{{ s.name }}</option>
      </select>
    </div>

    <div class="form-row">
      <label>Members</label>
      <div class="children-type-row">
        <label class="radio-label">
          <input type="radio" v-model="childrenType" value="lga" /> LGAs
        </label>
        <label class="radio-label">
          <input type="radio" v-model="childrenType" value="zone" /> Child zones
        </label>
      </div>
    </div>

    <div class="member-list">
      <div class="member-actions">
        <button class="link-btn" @click="selectAll">All</button>
        <button class="link-btn" @click="clearAll">None</button>
        <span class="member-count">{{ selectedPcodes.size }} selected</span>
      </div>
      <div class="member-scroll">
        <label
          v-for="child in childOptions" :key="child.pcode"
          class="member-item"
          :class="{ checked: selectedPcodes.has(child.pcode) }"
        >
          <input type="checkbox" :checked="selectedPcodes.has(child.pcode)" @change="togglePcode(child.pcode)" />
          <span>{{ child.name }}</span>
        </label>
        <div v-if="childOptions.length === 0" class="empty-members">
          No members available
        </div>
      </div>
    </div>

    <div class="form-actions">
      <button class="btn-primary" @click="submit" :disabled="!name.trim()">
        {{ editZone ? 'Update zone' : 'Create zone' }}
      </button>
      <button class="btn-cancel" @click="emit('cancel')">Cancel</button>
    </div>
  </div>
</template>

<style scoped>
.zone-form {
  background: #f8fafc;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.form-row { display: flex; flex-direction: column; gap: 3px; }
.form-row label { font-size: 11px; font-weight: 600; color: #64748b; text-transform: uppercase; letter-spacing: 0.04em; }
.form-input { border: 1px solid #cbd5e1; border-radius: 5px; padding: 5px 8px; font-size: 13px; color: #0f172a; background: #fff; width: 100%; box-sizing: border-box; }
.form-input:focus { outline: none; border-color: #3b82f6; }

.type-row { display: flex; gap: 6px; }
.color-row { display: flex; align-items: center; gap: 5px; flex-wrap: wrap; }
.color-swatch {
  width: 18px; height: 18px; border-radius: 4px; cursor: pointer;
  border: 2px solid transparent; transition: border-color 0.1s;
}
.color-swatch.active { border-color: #0f172a; }
.color-swatch:hover { transform: scale(1.15); }
.color-picker { width: 24px; height: 24px; border: none; background: none; cursor: pointer; padding: 0; border-radius: 4px; }

.children-type-row { display: flex; gap: 12px; }
.radio-label { font-size: 13px; color: #475569; display: flex; align-items: center; gap: 4px; cursor: pointer; }

.member-list { display: flex; flex-direction: column; gap: 4px; }
.member-actions { display: flex; align-items: center; gap: 8px; }
.link-btn { background: none; border: none; color: #3b82f6; font-size: 12px; cursor: pointer; padding: 0; }
.link-btn:hover { text-decoration: underline; }
.member-count { font-size: 11px; color: #94a3b8; margin-left: auto; }

.member-scroll {
  max-height: 150px;
  overflow-y: auto;
  border: 1px solid #e2e8f0;
  border-radius: 6px;
  background: #fff;
}
.member-item {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 4px 8px;
  font-size: 12px;
  color: #334155;
  cursor: pointer;
  transition: background 0.08s;
}
.member-item:hover { background: #f1f5f9; }
.member-item.checked { background: #eff6ff; }
.empty-members { padding: 8px; font-size: 12px; color: #94a3b8; text-align: center; }

.form-actions { display: flex; gap: 8px; margin-top: 4px; }
.btn-primary {
  background: #3b82f6; color: #fff; border: none; border-radius: 5px;
  padding: 6px 14px; font-size: 13px; cursor: pointer; flex: 1;
}
.btn-primary:hover:not(:disabled) { background: #2563eb; }
.btn-primary:disabled { opacity: 0.5; cursor: default; }
.btn-cancel {
  background: #f1f5f9; color: #475569; border: 1px solid #e2e8f0;
  border-radius: 5px; padding: 6px 14px; font-size: 13px; cursor: pointer;
}
.btn-cancel:hover { background: #e2e8f0; }
</style>
