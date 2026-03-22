<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from '../composables/useTileInspector';
import Tree from 'primevue/tree';
import type { TreeNode } from 'primevue/treenode';
import InputText from 'primevue/inputtext';
import Select from 'primevue/select';
import Button from 'primevue/button';

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'created'): void;
}>();

const { reloadTenantList, selectedTenantId } = useTileInspector();
const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

const COUNTRY_OPTIONS = [
  { label: 'Kenya (KE)', value: 'KE' },
  { label: 'Uganda (UG)', value: 'UG' },
  { label: 'Nigeria (NG)', value: 'NG' },
  { label: 'Liberia (LR)', value: 'LR' },
  { label: 'India (IN)', value: 'IN' },
  { label: 'Rwanda (RW)', value: 'RW' },
  { label: 'Central African Republic (CF)', value: 'CF' },
];

const SOURCE_HINTS: Record<string, { tile: string; boundary: string }> = {
  KE: { tile: 'kenya-detailed',                      boundary: 'kenya-boundaries' },
  UG: { tile: 'uganda-detailed',                     boundary: 'uganda-boundaries' },
  NG: { tile: 'nigeria-<state>',                     boundary: 'nigeria-<state>-boundaries' },
  LR: { tile: 'liberia-detailed',                    boundary: 'liberia-boundaries' },
  IN: { tile: 'india-<state>',                       boundary: 'india-boundaries' },
  RW: { tile: 'rwanda-detailed',                     boundary: 'rwanda-boundaries' },
  CF: { tile: 'central-african-republic-detailed',   boundary: 'central-african-republic-boundaries' },
};

// ── Fields ──────────────────────────────────────────────────────────────────
const tenantId       = ref('');
const countryCode    = ref('');
const tenantName     = ref('');
const tileSource     = ref('');
const boundarySource = ref('');

// ── Tenant ID validation ─────────────────────────────────────────────────────
const idValidating = ref(false);
const idError      = ref('');
const idValid      = ref(false);

async function validateId() {
  const id = String(tenantId.value).trim();
  if (!id || !/^\d+$/.test(id) || Number(id) <= 0) {
    idError.value = 'Enter a positive integer';
    idValid.value = false;
    return;
  }
  idValidating.value = true;
  idError.value = '';
  try {
    const res = await fetch(`${BASE}/admin/tenants`);
    if (res.ok) {
      const data = await res.json();
      const existing = (data.tenants ?? []).map((t: any) => String(t.tenant_id));
      if (existing.includes(id)) {
        idError.value = `ID ${id} already exists`;
        idValid.value = false;
        return;
      }
    }
    idValid.value = true;
  } catch {
    idValid.value = true; // allow if API unreachable
  } finally {
    idValidating.value = false;
  }
}

// ── Country → auto-fill sources ──────────────────────────────────────────────
function onCountryChange() {
  const hint = SOURCE_HINTS[countryCode.value];
  tileSource.value     = hint?.tile     ?? '';
  boundarySource.value = hint?.boundary ?? '';
  loadStates();
}

// ── State/LGA tree ───────────────────────────────────────────────────────────
interface LGA   { pcode: string; name: string }
interface State { pcode: string; name: string; lgas: LGA[] }

const states       = ref<State[]>([]);
const statesLoading = ref(false);
const statesError   = ref('');
const searchQ       = ref('');
const selectionKeys = ref<Record<string, { checked: boolean; partialChecked: boolean }>>({});
const selectedPcodes = ref<string[]>([]);

async function loadStates() {
  if (!countryCode.value) return;
  statesLoading.value = true;
  statesError.value   = '';
  states.value        = [];
  selectionKeys.value = {};
  selectedPcodes.value = [];
  try {
    const res = await fetch(`${BASE}/admin/states?country_code=${countryCode.value}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    states.value = (data.states ?? []).map((s: any) => ({
      pcode: s.pcode,
      name:  s.name,
      lgas:  s.children ?? s.lgas ?? [],
    }));
  } catch (e: any) {
    statesError.value = e.message ?? 'Failed to load states';
  } finally {
    statesLoading.value = false;
  }
}

const treeNodes = computed<TreeNode[]>(() => {
  const q = searchQ.value.toLowerCase().trim();
  return states.value
    .map((state): TreeNode | null => {
      const matchesState = !q || state.name.toLowerCase().includes(q) || state.pcode.toLowerCase().includes(q);
      const filteredLgas = q
        ? state.lgas.filter(l => l.name.toLowerCase().includes(q) || l.pcode.toLowerCase().includes(q))
        : state.lgas;
      if (!matchesState && filteredLgas.length === 0) return null;
      return {
        key: state.pcode,
        label: state.name,
        data: state,
        children: (matchesState ? state.lgas : filteredLgas).map(lga => ({
          key: lga.pcode, label: lga.name, data: lga, leaf: true,
        })),
      };
    })
    .filter((n): n is TreeNode => n !== null);
});

const selectedCount = computed(() => {
  const allLgaPcodes = new Set(states.value.flatMap(s => s.lgas.map(l => l.pcode)));
  return Object.keys(selectionKeys.value).filter(
    k => selectionKeys.value[k].checked && allLgaPcodes.has(k)
  ).length;
});

function onSelectionChange(keys: Record<string, { checked: boolean; partialChecked: boolean }>) {
  selectionKeys.value = keys;
  const allLgaPcodes = new Set(states.value.flatMap(s => s.lgas.map(l => l.pcode)));
  selectedPcodes.value = Object.keys(keys).filter(k => keys[k].checked && allLgaPcodes.has(k));
}

function selectAll() {
  const keys: Record<string, { checked: boolean; partialChecked: boolean }> = {};
  for (const state of states.value) {
    keys[state.pcode] = { checked: true, partialChecked: false };
    for (const lga of state.lgas) keys[lga.pcode] = { checked: true, partialChecked: false };
  }
  selectionKeys.value  = keys;
  selectedPcodes.value = states.value.flatMap(s => s.lgas.map(l => l.pcode));
}

function clearAll() {
  selectionKeys.value  = {};
  selectedPcodes.value = [];
}

// ── Submit ───────────────────────────────────────────────────────────────────
const saving   = ref(false);
const errorMsg = ref('');

const canCreate = computed(() =>
  idValid.value &&
  countryCode.value &&
  tenantName.value.trim() &&
  tileSource.value.trim()
);

async function createTenant() {
  saving.value   = true;
  errorMsg.value = '';
  try {
    const res = await fetch(`${BASE}/admin/tenants`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tenant_id:       Number(tenantId.value),
        country_code:    countryCode.value,
        country_name:    tenantName.value.trim(),
        tile_source:     tileSource.value.trim(),
        boundary_source: boundarySource.value.trim(),
      }),
    });
    if (!res.ok) {
      const d = await res.json().catch(() => ({}));
      throw new Error(d.error ?? `HTTP ${res.status}`);
    }

    if (selectedPcodes.value.length > 0) {
      await fetch(`${BASE}/admin/territories`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': tenantId.value },
        body: JSON.stringify({ pcodes: selectedPcodes.value }),
      });
    }

    await reloadTenantList();
    selectedTenantId.value = tenantId.value;
    emit('created');
    emit('close');
  } catch (e: any) {
    errorMsg.value = e.message ?? 'Failed to create tenant';
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <!-- Backdrop -->
  <div class="panel-backdrop" @click.self="emit('close')" />

  <!-- Panel -->
  <div class="add-tenant-panel">
    <!-- Header -->
    <div class="atp-header">
      <div class="atp-title">
        <i class="pi pi-plus-circle text-indigo-500 text-[11px]" />
        <span>Add New Tenant</span>
      </div>
      <button type="button" class="atp-close" title="Close" @click="emit('close')">
        <i class="pi pi-times text-[10px]" />
      </button>
    </div>

    <!-- Body: two columns -->
    <div class="atp-body">

      <!-- LEFT: fields -->
      <div class="atp-fields">
        <!-- Tenant ID -->
        <div class="field-group">
          <label class="field-label">Tenant ID</label>
          <div class="flex gap-1.5">
            <InputText
              v-model="tenantId"
              type="number"
              placeholder="e.g. 20"
              class="flex-1 !text-sm"
              :class="{ 'p-invalid': idError }"
              @input="idValid = false; idError = ''"
              @keyup.enter="validateId"
            />
            <Button
              label="Check"
              size="small"
              variant="outlined"
              :loading="idValidating"
              @click="validateId"
            />
          </div>
          <p v-if="idError" class="field-error">{{ idError }}</p>
          <p v-else-if="idValid" class="field-ok">
            <i class="pi pi-check-circle mr-1" />ID {{ tenantId }} is available
          </p>
        </div>

        <!-- Country -->
        <div class="field-group">
          <label class="field-label">Country</label>
          <Select
            v-model="countryCode"
            :options="COUNTRY_OPTIONS"
            optionValue="value"
            optionLabel="label"
            placeholder="— select —"
            class="w-full !text-sm"
            @change="onCountryChange"
          />
        </div>

        <!-- Tenant Name -->
        <div class="field-group">
          <label class="field-label">Tenant name</label>
          <InputText v-model="tenantName" placeholder="e.g. Bridge Tanzania" class="w-full !text-sm" />
        </div>

        <!-- Tile Source -->
        <div class="field-group">
          <label class="field-label">Tile source</label>
          <InputText v-model="tileSource" placeholder="e.g. kenya-detailed" class="w-full !text-sm" />
        </div>

        <!-- Boundary Source -->
        <div class="field-group">
          <label class="field-label">Boundary source</label>
          <InputText v-model="boundarySource" placeholder="e.g. kenya-boundaries" class="w-full !text-sm" />
        </div>
      </div>

      <!-- RIGHT: state/LGA tree -->
      <div class="atp-tree-col">
        <div class="atp-tree-header">
          <span class="field-label mb-0">States &amp; LGAs in scope</span>
          <span class="text-xs text-slate-400">{{ selectedCount > 0 ? `${selectedCount} selected` : 'optional' }}</span>
        </div>

        <div v-if="!countryCode" class="atp-tree-placeholder">
          Select a country to browse states
        </div>
        <div v-else-if="statesLoading" class="atp-tree-placeholder">
          Loading {{ countryCode }} states…
        </div>
        <div v-else-if="statesError" class="atp-tree-placeholder text-red-500">
          {{ statesError }}
        </div>
        <template v-else>
          <div class="flex flex-col gap-1.5 flex-shrink-0">
            <InputText
              v-model="searchQ"
              placeholder="Search states or LGAs…"
              class="w-full !text-xs"
            />
            <div class="flex items-center gap-1">
              <Button label="All" size="small" variant="text" class="!text-xs !py-0.5 !px-2" @click="selectAll" />
              <Button label="Clear" size="small" variant="text" class="!text-xs !py-0.5 !px-2" @click="clearAll" />
            </div>
          </div>
          <div class="atp-tree-scroll">
            <Tree
              :value="treeNodes"
              selectionMode="checkbox"
              v-model:selectionKeys="selectionKeys"
              @update:selectionKeys="onSelectionChange"
              class="w-full !text-xs"
            />
            <div v-if="treeNodes.length === 0" class="p-3 text-center text-xs text-slate-400">
              No results
            </div>
          </div>
        </template>
      </div>
    </div>

    <!-- Footer -->
    <div class="atp-footer">
      <p v-if="errorMsg" class="text-xs text-red-500 flex-1">{{ errorMsg }}</p>
      <span class="flex-1" />
      <Button label="Cancel" variant="outlined" size="small" @click="emit('close')" />
      <Button
        label="Create Tenant"
        icon="pi pi-check"
        severity="success"
        size="small"
        :loading="saving"
        :disabled="!canCreate"
        @click="createTenant"
      />
    </div>
  </div>
</template>

<style scoped>
.panel-backdrop {
  position: fixed;
  inset: 0;
  z-index: 999;
  background: rgba(0, 0, 0, 0.35);
  backdrop-filter: blur(2px);
}

.add-tenant-panel {
  position: fixed;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  z-index: 1000;
  width: min(860px, calc(100vw - 24px));
  height: min(640px, calc(100vh - 56px));
  display: flex;
  flex-direction: column;
  background: rgba(255, 255, 255, 0.97);
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  border-radius: 12px;
  box-shadow:
    0 4px 24px rgba(0, 0, 0, 0.12),
    0 1px 4px rgba(0, 0, 0, 0.08),
    0 0 0 1px rgba(0, 0, 0, 0.06);
  overflow: hidden;
}

/* ── Header ── */
.atp-header {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 10px 14px;
  border-bottom: 1px solid rgba(0,0,0,0.07);
  flex-shrink: 0;
}
.atp-title {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
  color: #1e293b;
  letter-spacing: 0.01em;
  flex: 1;
}
.atp-close {
  width: 22px;
  height: 22px;
  border: none;
  background: transparent;
  border-radius: 5px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #64748b;
  transition: background 0.12s, color 0.12s;
}
.atp-close:hover { background: #f1f5f9; color: #0f172a; }

/* ── Body ── */
.atp-body {
  display: flex;
  flex: 1;
  overflow: hidden;
  gap: 0;
}

/* Left fields column */
.atp-fields {
  width: 300px;
  flex-shrink: 0;
  padding: 14px 16px;
  border-right: 1px solid rgba(0,0,0,0.07);
  display: flex;
  flex-direction: column;
  gap: 14px;
  overflow-y: auto;
}

.field-group {
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.field-label {
  font-size: 10px;
  font-weight: 600;
  color: #64748b;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  display: flex;
  align-items: center;
  margin-bottom: 1px;
}
.field-error { font-size: 11px; color: #dc2626; }
.field-ok    { font-size: 11px; color: #16a34a; }

/* Right tree column */
.atp-tree-col {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 14px 16px;
  overflow: hidden;
  min-width: 0;
}
.atp-tree-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-shrink: 0;
}
.atp-tree-placeholder {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  color: #94a3b8;
}
.atp-tree-scroll {
  flex: 1;
  overflow-y: auto;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  background: #fff;
}

/* ── Footer ── */
.atp-footer {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  border-top: 1px solid rgba(0,0,0,0.07);
  flex-shrink: 0;
}
</style>
