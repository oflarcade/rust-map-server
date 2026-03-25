<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import Tree from 'primevue/tree';
import type { TreeNode } from 'primevue/treenode';
import InputText from 'primevue/inputtext';
import Button from 'primevue/button';

const props = defineProps<{
  countryCode: string;
  selected?: string[];
}>();

const emit = defineEmits<{
  (e: 'update:selected', pcodes: string[]): void;
}>();

interface LGA { pcode: string; name: string; }
interface State { pcode: string; name: string; lgas: LGA[]; }

const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);
const states = ref<State[]>([]);
const loading = ref(false);
const error = ref('');
const searchQ = ref('');

// PrimeVue Tree checkbox format: Record<string, { checked: boolean; partialChecked: boolean }>
const selectionKeys = ref<Record<string, { checked: boolean; partialChecked: boolean }>>({});

async function loadStates() {
  if (!props.countryCode) return;
  loading.value = true;
  error.value = '';
  try {
    const res = await fetch(`${BASE}/admin/states?country_code=${props.countryCode}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    // API returns `children`, map to `lgas`
    states.value = (data.states ?? []).map((s: any) => ({
      pcode: s.pcode,
      name: s.name,
      adm2s: s.children ?? s.adm2s ?? [],
    }));
    // After loading, sync selection from props
    syncSelectionFromProps();
  } catch (e: any) {
    error.value = e.message ?? 'Failed to load states';
  } finally {
    loading.value = false;
  }
}

function syncSelectionFromProps() {
  const selected = new Set(props.selected ?? []);
  const keys: Record<string, { checked: boolean; partialChecked: boolean }> = {};
  for (const state of states.value) {
    const lgaPcodes = (state as any).adm2s.map((a: any) => a.pcode);
    const checkedCount = lgaPcodes.filter((p: string) => selected.has(p)).length;
    for (const adm2 of (state as any).adm2s) {
      if (selected.has(adm2.pcode)) {
        keys[adm2.pcode] = { checked: true, partialChecked: false };
      }
    }
    if (checkedCount === lgaPcodes.length && lgaPcodes.length > 0) {
      keys[state.pcode] = { checked: true, partialChecked: false };
    } else if (checkedCount > 0) {
      keys[state.pcode] = { checked: false, partialChecked: true };
    }
  }
  selectionKeys.value = keys;
}

watch(() => props.countryCode, loadStates, { immediate: true });

watch(() => props.selected, () => {
  syncSelectionFromProps();
}, { deep: true });

// Convert selectionKeys back to array of leaf LGA pcodes
function onSelectionChange(keys: Record<string, { checked: boolean; partialChecked: boolean }>) {
  selectionKeys.value = keys;
  const allAdm2Pcodes = new Set(states.value.flatMap((s: any) => s.adm2s.map((a: any) => a.pcode)));
  const selected = Object.keys(keys).filter(
    (k) => keys[k].checked && allAdm2Pcodes.has(k)
  );
  emit('update:selected', selected);
}

// Filtered tree nodes for search
const treeNodes = computed<TreeNode[]>(() => {
  const q = searchQ.value.toLowerCase().trim();
  return states.value
    .map((state): TreeNode | null => {
      const matchesState =
        !q || state.name.toLowerCase().includes(q) || state.pcode.toLowerCase().includes(q);
      const filteredAdm2s = q
        ? (state as any).adm2s.filter(
            (a: any) =>
              a.name.toLowerCase().includes(q) || a.pcode.toLowerCase().includes(q)
          )
        : (state as any).adm2s;
      if (!matchesState && filteredAdm2s.length === 0) return null;
      return {
        key: state.pcode,
        label: state.name,
        data: state,
        children: (matchesState ? (state as any).adm2s : filteredAdm2s).map(
          (a: any): TreeNode => ({
            key: a.pcode,
            label: a.name,
            data: a,
            leaf: true,
          })
        ),
      };
    })
    .filter((n): n is TreeNode => n !== null);
});

const selectedCount = computed(() => {
  const allAdm2Pcodes = new Set(states.value.flatMap((s: any) => s.adm2s.map((a: any) => a.pcode)));
  return Object.keys(selectionKeys.value).filter(
    (k) => selectionKeys.value[k].checked && allAdm2Pcodes.has(k)
  ).length;
});

function selectAll() {
  const keys: Record<string, { checked: boolean; partialChecked: boolean }> = {};
  for (const state of states.value) {
    keys[state.pcode] = { checked: true, partialChecked: false };
    for (const adm2 of (state as any).adm2s) {
      keys[adm2.pcode] = { checked: true, partialChecked: false };
    }
  }
  selectionKeys.value = keys;
  const allPcodes = states.value.flatMap((s: any) => s.adm2s.map((a: any) => a.pcode));
  emit('update:selected', allPcodes);
}

function clearAll() {
  selectionKeys.value = {};
  emit('update:selected', []);
}
</script>

<template>
  <div class="flex flex-col gap-2 h-full">
    <div v-if="loading" class="text-sm text-slate-500 py-3 text-center">
      Loading {{ countryCode }} states…
    </div>
    <div v-else-if="error" class="text-sm text-red-600 py-3 text-center">{{ error }}</div>
    <template v-else>
      <div class="flex flex-col gap-1.5">
        <InputText
          v-model="searchQ"
          placeholder="Search states or LGAs…"
          class="w-full !text-sm"
        />
        <div class="flex items-center gap-2">
          <Button label="Select All" size="small" variant="text" @click="selectAll()" />
          <Button label="Clear" size="small" variant="text" @click="clearAll()" />
          <span class="ml-auto text-xs text-slate-400">{{ selectedCount }} LGAs selected</span>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto border border-slate-200 rounded-lg bg-white">
        <Tree
          :value="treeNodes"
          selectionMode="checkbox"
          v-model:selectionKeys="selectionKeys"
          @update:selectionKeys="onSelectionChange"
          class="w-full !text-sm"
        />
        <div
          v-if="treeNodes.length === 0 && !loading"
          class="p-4 text-center text-sm text-slate-400"
        >
          No results
        </div>
      </div>
    </template>
  </div>
</template>
