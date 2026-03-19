<script setup lang="ts">
import { ref, watch, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';

const props = defineProps<{ countryCode: string }>();

const emit = defineEmits<{
  (e: 'update:selected', pcodes: string[]): void;
}>();

interface LGA { pcode: string; name: string; }
interface State { pcode: string; name: string; children: LGA[]; }

const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);
const states = ref<State[]>([]);
const loading = ref(false);
const error = ref('');
const expanded = ref<Set<string>>(new Set());
const checked = ref<Set<string>>(new Set());
const searchQ = ref('');

async function loadStates() {
  if (!props.countryCode) return;
  loading.value = true;
  error.value = '';
  try {
    const res = await fetch(`${BASE}/admin/states?country_code=${props.countryCode}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    states.value = data.states ?? [];
    expanded.value = new Set(states.value.map((s) => s.pcode)); // expand all by default
  } catch (e: any) {
    error.value = e.message ?? 'Failed to load states';
  } finally {
    loading.value = false;
  }
}

watch(() => props.countryCode, loadStates, { immediate: true });
watch(checked, () => {
  emit('update:selected', Array.from(checked.value));
}, { deep: true });

const filteredStates = computed(() => {
  const q = searchQ.value.toLowerCase().trim();
  if (!q) return states.value;
  return states.value
    .map((s) => {
      if (s.name.toLowerCase().includes(q) || s.pcode.toLowerCase().includes(q)) return s;
      const children = s.children.filter((c) => c.name.toLowerCase().includes(q) || c.pcode.toLowerCase().includes(q));
      if (children.length) return { ...s, children };
      return null;
    })
    .filter(Boolean) as State[];
});

function toggleExpand(pcode: string) {
  const next = new Set(expanded.value);
  if (next.has(pcode)) next.delete(pcode); else next.add(pcode);
  expanded.value = next;
}

function toggleLga(pcode: string) {
  const next = new Set(checked.value);
  if (next.has(pcode)) next.delete(pcode); else next.add(pcode);
  checked.value = next;
}

function toggleState(state: State) {
  const lgaPcodes = state.children.map((c) => c.pcode);
  const allChecked = lgaPcodes.every((p) => checked.value.has(p));
  const next = new Set(checked.value);
  if (allChecked) lgaPcodes.forEach((p) => next.delete(p));
  else lgaPcodes.forEach((p) => next.add(p));
  checked.value = next;
}

function stateCheckState(state: State): 'all' | 'none' | 'partial' {
  const lgaPcodes = state.children.map((c) => c.pcode);
  const count = lgaPcodes.filter((p) => checked.value.has(p)).length;
  if (count === 0) return 'none';
  if (count === lgaPcodes.length) return 'all';
  return 'partial';
}

function selectAll() {
  checked.value = new Set(states.value.flatMap((s) => s.children.map((c) => c.pcode)));
}
function clearAll() { checked.value = new Set(); }
</script>

<template>
  <div class="w3-root">
    <div v-if="loading" class="loading-msg">Loading {{ countryCode }} states…</div>
    <div v-else-if="error" class="error-msg">{{ error }}</div>
    <template v-else>
      <div class="toolbar">
        <input v-model="searchQ" placeholder="Search states / LGAs…" class="search-input" />
        <div class="bulk-actions">
          <button class="link-btn" @click="selectAll">Select all</button>
          <button class="link-btn" @click="clearAll">Clear all</button>
          <span class="count-text">{{ checked.size }} LGAs selected</span>
        </div>
      </div>

      <div class="tree-scroll">
        <div v-for="state in filteredStates" :key="state.pcode" class="state-block">
          <div class="state-row" @click="toggleExpand(state.pcode)">
            <span class="expand-icon">{{ expanded.has(state.pcode) ? '▾' : '▸' }}</span>
            <input
              type="checkbox"
              :checked="stateCheckState(state) === 'all'"
              :indeterminate="stateCheckState(state) === 'partial'"
              @click.stop="toggleState(state)"
              class="state-checkbox"
            />
            <span class="state-name">{{ state.name }}</span>
            <span class="state-pcode">{{ state.pcode }}</span>
            <span class="state-count">{{ state.children.length }}</span>
          </div>

          <div v-if="expanded.has(state.pcode)" class="lga-list">
            <label
              v-for="lga in state.children"
              :key="lga.pcode"
              class="lga-row"
              :class="{ checked: checked.has(lga.pcode) }"
            >
              <input type="checkbox" :checked="checked.has(lga.pcode)" @change="toggleLga(lga.pcode)" />
              <span class="lga-name">{{ lga.name }}</span>
              <span class="lga-pcode">{{ lga.pcode }}</span>
            </label>
          </div>
        </div>

        <div v-if="filteredStates.length === 0 && !loading" class="empty-msg">No results</div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.w3-root { display: flex; flex-direction: column; gap: 8px; height: 100%; }
.loading-msg, .error-msg { font-size: 13px; color: #64748b; padding: 12px 0; text-align: center; }
.error-msg { color: #dc2626; }

.toolbar { display: flex; flex-direction: column; gap: 6px; }
.search-input {
  width: 100%; box-sizing: border-box; border: 1px solid #e2e8f0; border-radius: 6px;
  padding: 6px 10px; font-size: 13px;
}
.search-input:focus { outline: none; border-color: #3b82f6; }
.bulk-actions { display: flex; align-items: center; gap: 10px; }
.link-btn { background: none; border: none; color: #3b82f6; font-size: 12px; cursor: pointer; padding: 0; }
.link-btn:hover { text-decoration: underline; }
.count-text { font-size: 12px; color: #94a3b8; margin-left: auto; }

.tree-scroll { flex: 1; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 8px; background: #fff; }

.state-block { }
.state-row {
  display: flex; align-items: center; gap: 7px;
  padding: 7px 10px; cursor: pointer; background: #f8fafc;
  border-bottom: 1px solid #e2e8f0;
  position: sticky; top: 0; z-index: 1;
}
.state-row:hover { background: #f1f5f9; }
.expand-icon { font-size: 9px; color: #94a3b8; flex-shrink: 0; }
.state-checkbox { flex-shrink: 0; cursor: pointer; }
.state-name { flex: 1; font-size: 13px; font-weight: 600; color: #0f172a; }
.state-pcode { font-size: 11px; color: #94a3b8; flex-shrink: 0; }
.state-count { font-size: 11px; color: #94a3b8; background: #e2e8f0; padding: 1px 5px; border-radius: 10px; flex-shrink: 0; }

.lga-list { }
.lga-row {
  display: flex; align-items: center; gap: 7px;
  padding: 4px 10px 4px 28px; cursor: pointer; border-bottom: 1px solid #f1f5f9;
  font-size: 12px;
}
.lga-row:last-child { border-bottom: none; }
.lga-row:hover { background: #f8fafc; }
.lga-row.checked { background: #eff6ff; }
.lga-name { flex: 1; color: #334155; }
.lga-pcode { font-size: 10px; color: #94a3b8; flex-shrink: 0; }

.empty-msg { padding: 16px; text-align: center; font-size: 13px; color: #94a3b8; }
</style>
