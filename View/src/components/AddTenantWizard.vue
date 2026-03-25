<script setup lang="ts">
import { ref, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { deriveNigeriaMartinSources } from '../lib/martinSources';
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

const { reloadTenantList, selectedTenantId, hierarchyEditorOpen } = useTileInspector();
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

const COUNTRY_SLUG: Record<string, string> = {
  KE: 'kenya', UG: 'uganda', LR: 'liberia', RW: 'rwanda',
  CF: 'central-african-republic', IN: 'india', NG: 'nigeria',
};

// ── Fields ──────────────────────────────────────────────────────────────────
const tenantId    = ref('');
const countryCode = ref('');
const tenantName  = ref('');

// ── Auto-derived sources ─────────────────────────────────────────────────────
const showAdvanced     = ref(false);
const tileOverride     = ref('');
const boundaryOverride = ref('');

const derivedSources = computed(() => {
  const cc = countryCode.value;
  if (!cc) return { tile: '', boundary: '' };
  const slug = COUNTRY_SLUG[cc] ?? cc.toLowerCase();

  const active = states.value.filter(s => {
    const k = selectionKeys.value[s.pcode];
    return k && (k.checked || k.partialChecked);
  });

  if (cc === 'NG' && active.length > 0) {
    return deriveNigeriaMartinSources(active.map(s => s.name));
  }
  if (cc === 'IN' && active.length > 0) {
    const name = active[0].name.toLowerCase().replace(/\s+/g, '');
    return { tile: `india-${name}`, boundary: 'india-boundaries' };
  }
  return { tile: `${slug}-detailed`, boundary: `${slug}-boundaries` };
});

const tileSource     = computed(() => tileOverride.value.trim()     || derivedSources.value.tile);
const boundarySource = computed(() => boundaryOverride.value.trim() || derivedSources.value.boundary);

/** Display + submit name: manual entry, or auto "Bridge {State(s)}" when NG/IN scope is chosen. */
const effectiveTenantName = computed(() => {
  const manual = tenantName.value.trim();
  if (manual) return manual;
  const cc = countryCode.value;
  if (cc !== 'NG' && cc !== 'IN') return '';
  const active = states.value.filter((s) => {
    const k = selectionKeys.value[s.pcode];
    return k && (k.checked || k.partialChecked);
  });
  if (active.length === 0) return '';
  return `Bridge ${active.map((s) => s.name).join(' + ')}`;
});

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

// ── Country change ────────────────────────────────────────────────────────────
function onCountryChange() {
  tileOverride.value     = '';
  boundaryOverride.value = '';
  showAdvanced.value     = false;
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
      adm2s: s.children ?? s.adm2s ?? [],
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
      const filteredAdm2s = q
        ? state.adm2s.filter((a: any) => a.name.toLowerCase().includes(q) || a.pcode.toLowerCase().includes(q))
        : state.adm2s;
      if (!matchesState && filteredAdm2s.length === 0) return null;
      return {
        key: state.pcode,
        label: state.name,
        data: state,
        children: (matchesState ? state.adm2s : filteredAdm2s).map((a: any) => ({
          key: a.pcode, label: a.name, data: a, leaf: true,
        })),
      };
    })
    .filter((n): n is TreeNode => n !== null);
});

const selectedCount = computed(() => {
  const allAdm2Pcodes = new Set(states.value.flatMap((s: any) => s.adm2s.map((a: any) => a.pcode)));
  return Object.keys(selectionKeys.value).filter(
    k => selectionKeys.value[k].checked && allAdm2Pcodes.has(k)
  ).length;
});

function onSelectionChange(keys: Record<string, { checked: boolean; partialChecked: boolean }>) {
  selectionKeys.value = keys;
  const allAdm2Pcodes = new Set(states.value.flatMap((s: any) => s.adm2s.map((a: any) => a.pcode)));
  selectedPcodes.value = Object.keys(keys).filter(k => keys[k].checked && allAdm2Pcodes.has(k));
}

function selectAll() {
  const keys: Record<string, { checked: boolean; partialChecked: boolean }> = {};
  for (const state of states.value) {
    keys[(state as any).pcode] = { checked: true, partialChecked: false };
    for (const adm2 of (state as any).adm2s) keys[adm2.pcode] = { checked: true, partialChecked: false };
  }
  selectionKeys.value  = keys;
  selectedPcodes.value = states.value.flatMap((s: any) => s.adm2s.map((a: any) => a.pcode));
}

function clearAll() {
  selectionKeys.value  = {};
  selectedPcodes.value = [];
}

// ── Submit ───────────────────────────────────────────────────────────────────
const saving   = ref(false);
const errorMsg = ref('');
const created  = ref(false);

const canCreate = computed(() =>
  idValid.value &&
  countryCode.value &&
  !!effectiveTenantName.value &&
  !!derivedSources.value.tile
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
        country_name:    effectiveTenantName.value,
        tile_source:     tileSource.value,
        boundary_source: boundarySource.value,
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
    created.value = true;
  } catch (e: any) {
    errorMsg.value = e.message ?? 'Failed to create tenant';
  } finally {
    saving.value = false;
  }
}

function openHierarchyEditor() {
  hierarchyEditorOpen.value = true;
  emit('close');
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
          <InputText v-model="tenantName" placeholder="e.g. Bridge Adamawa (optional if states selected)" class="w-full !text-sm" />
          <p v-if="(countryCode === 'NG' || countryCode === 'IN') && !tenantName.trim() && effectiveTenantName" class="mt-1 text-[11px] text-slate-500">
            Will use: <strong>{{ effectiveTenantName }}</strong>
          </p>
        </div>

        <!-- Auto-derived sources preview -->
        <div v-if="derivedSources.tile" class="field-group">
          <div class="flex items-center justify-between">
            <label class="field-label mb-0">Sources (auto)</label>
            <button
              type="button"
              class="text-[10px] text-slate-400 hover:text-slate-600 transition-colors"
              @click="showAdvanced = !showAdvanced"
            >
              {{ showAdvanced ? 'Hide' : 'Override' }}
            </button>
          </div>
          <div class="bg-slate-50 rounded px-2 py-1.5 text-[11px] font-mono text-slate-600 leading-relaxed border border-slate-100">
            <div>tiles: {{ tileSource }}</div>
            <div>bounds: {{ boundarySource }}</div>
          </div>
        </div>

        <!-- Advanced override (hidden by default) -->
        <template v-if="showAdvanced">
          <div class="field-group">
            <label class="field-label">Tile source override</label>
            <InputText v-model="tileOverride" :placeholder="derivedSources.tile" class="w-full !text-sm" />
          </div>
          <div class="field-group">
            <label class="field-label">Boundary source override</label>
            <InputText v-model="boundaryOverride" :placeholder="derivedSources.boundary" class="w-full !text-sm" />
          </div>
        </template>
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
      <template v-if="created">
        <div class="flex items-center gap-1.5 text-green-700 text-xs flex-1">
          <i class="pi pi-check-circle" />
          Tenant {{ tenantId }} created
        </div>
        <Button label="Done" variant="outlined" size="small" @click="emit('close')" />
        <Button
          label="Set up hierarchy →"
          severity="secondary"
          size="small"
          @click="openHierarchyEditor"
        />
      </template>
      <template v-else>
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
      </template>
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
