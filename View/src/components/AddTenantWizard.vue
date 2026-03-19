<script setup lang="ts">
import { ref, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from '../composables/useTileInspector';
import WizardStep3States from './WizardStep3States.vue';

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'created'): void;
}>();

const { reloadTenantList, selectedTenantId } = useTileInspector();
const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

const COUNTRY_OPTIONS = ['KE', 'UG', 'NG', 'LR', 'IN', 'RW', 'CF'];
const SOURCE_HINTS: Record<string, { tile: string; boundary: string }> = {
  KE: { tile: 'kenya-detailed', boundary: 'kenya-boundaries' },
  UG: { tile: 'uganda-detailed', boundary: 'uganda-boundaries' },
  NG: { tile: 'nigeria-<state>', boundary: 'nigeria-<state>-boundaries' },
  LR: { tile: 'liberia-detailed', boundary: 'liberia-boundaries' },
  IN: { tile: 'india-<state>', boundary: 'india-boundaries' },
  RW: { tile: 'rwanda-detailed', boundary: 'rwanda-boundaries' },
  CF: { tile: 'central-african-republic-detailed', boundary: 'central-african-republic-boundaries' },
};

const step = ref(1);
const saving = ref(false);
const errorMsg = ref('');

// Step 1
const tenantId = ref('');
const idValidating = ref(false);
const idError = ref('');
const idValid = ref(false);

// Step 2
const countryCode = ref('');
const tenantName = ref('');
const tileSource = ref('');
const boundarySource = ref('');

// Step 3
const selectedPcodes = ref<string[]>([]);

const hintSrc = computed(() => countryCode.value ? (SOURCE_HINTS[countryCode.value] ?? null) : null);

async function validateId() {
  const id = String(tenantId.value).trim();
  if (!id || !/^\d+$/.test(id) || Number(id) <= 0) {
    idError.value = 'Enter a positive integer ID';
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
        idError.value = `Tenant ID ${id} already exists`;
        idValid.value = false;
        return;
      }
    }
    idValid.value = true;
  } catch {
    // allow anyway if API is unreachable
    idValid.value = true;
  } finally {
    idValidating.value = false;
  }
}

function onCountryChange() {
  const hint = SOURCE_HINTS[countryCode.value];
  if (hint) {
    tileSource.value = hint.tile;
    boundarySource.value = hint.boundary;
  } else {
    tileSource.value = '';
    boundarySource.value = '';
  }
}

async function createTenant() {
  saving.value = true;
  errorMsg.value = '';
  try {
    // Create tenant
    const res = await fetch(`${BASE}/admin/tenants`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tenant_id: Number(tenantId.value),
        country_code: countryCode.value,
        country_name: tenantName.value.trim(),
        tile_source: tileSource.value.trim(),
        boundary_source: boundarySource.value.trim(),
      }),
    });
    if (!res.ok) {
      const d = await res.json().catch(() => ({}));
      throw new Error(d.error ?? `HTTP ${res.status}`);
    }

    // Add territory scope if LGAs selected
    if (selectedPcodes.value.length > 0) {
      await fetch(`${BASE}/admin/territories`, {
        method: 'POST',
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

const canProceedStep1 = computed(() => idValid.value);
const canProceedStep2 = computed(() => countryCode.value && tenantName.value.trim() && tileSource.value.trim());
</script>

<template>
  <Teleport to="body">
    <div class="wizard-backdrop" @click.self="emit('close')">
      <div class="wizard-modal">
        <!-- Header -->
        <div class="wizard-header">
          <div class="wizard-steps">
            <span v-for="i in 4" :key="i" class="step-dot" :class="{ active: step >= i, current: step === i }">{{ i }}</span>
          </div>
          <button class="close-btn" @click="emit('close')">✕</button>
        </div>

        <!-- Step 1: Tenant ID -->
        <div v-if="step === 1" class="wizard-body">
          <h3 class="step-title">Choose Tenant ID</h3>
          <p class="step-desc">Enter a unique numeric ID for the new tenant.</p>
          <div class="field-group">
            <label>Tenant ID</label>
            <div class="id-row">
              <input
                v-model="tenantId"
                type="number" min="1" placeholder="e.g. 20"
                class="form-input"
                @input="idValid = false; idError = ''"
                @keyup.enter="validateId"
              />
              <button class="btn-validate" @click="validateId" :disabled="idValidating">
                {{ idValidating ? '…' : 'Check' }}
              </button>
            </div>
            <div v-if="idError" class="field-error">{{ idError }}</div>
            <div v-if="idValid" class="field-ok">✓ ID {{ tenantId }} is available</div>
          </div>
        </div>

        <!-- Step 2: Country + Name + Sources -->
        <div v-else-if="step === 2" class="wizard-body">
          <h3 class="step-title">Country & Tile Sources</h3>
          <div class="field-group">
            <label>Country</label>
            <select v-model="countryCode" class="form-input" @change="onCountryChange">
              <option value="">— select —</option>
              <option v-for="cc in COUNTRY_OPTIONS" :key="cc" :value="cc">{{ cc }}</option>
            </select>
          </div>
          <div class="field-group">
            <label>Tenant name</label>
            <input v-model="tenantName" placeholder="e.g. Bridge Tanzania" class="form-input" />
          </div>
          <div class="field-group">
            <label>Tile source <span class="hint">{{ hintSrc?.tile }}</span></label>
            <input v-model="tileSource" placeholder="e.g. kenya-detailed" class="form-input" />
          </div>
          <div class="field-group">
            <label>Boundary source <span class="hint">{{ hintSrc?.boundary }}</span></label>
            <input v-model="boundarySource" placeholder="e.g. kenya-boundaries" class="form-input" />
          </div>
        </div>

        <!-- Step 3: States / LGAs tree -->
        <div v-else-if="step === 3" class="wizard-body wizard-body--tall">
          <h3 class="step-title">Select States & LGAs</h3>
          <p class="step-desc">Choose which LGAs this tenant operates in (optional).</p>
          <WizardStep3States
            :country-code="countryCode"
            v-model:selected="selectedPcodes"
          />
        </div>

        <!-- Step 4: Summary -->
        <div v-else-if="step === 4" class="wizard-body">
          <h3 class="step-title">Review & Create</h3>
          <div class="summary-table">
            <div class="summary-row"><span>Tenant ID</span><strong>{{ tenantId }}</strong></div>
            <div class="summary-row"><span>Country</span><strong>{{ countryCode }}</strong></div>
            <div class="summary-row"><span>Name</span><strong>{{ tenantName }}</strong></div>
            <div class="summary-row"><span>Tile source</span><strong>{{ tileSource }}</strong></div>
            <div class="summary-row"><span>Boundary source</span><strong>{{ boundarySource }}</strong></div>
            <div class="summary-row"><span>LGAs in scope</span><strong>{{ selectedPcodes.length }}</strong></div>
          </div>
          <div v-if="errorMsg" class="field-error" style="margin-top:8px">{{ errorMsg }}</div>
        </div>

        <!-- Footer -->
        <div class="wizard-footer">
          <button v-if="step > 1" class="btn-back" @click="step--">← Back</button>
          <span class="spacer"></span>
          <template v-if="step < 4">
            <button
              class="btn-next"
              :disabled="(step === 1 && !canProceedStep1) || (step === 2 && !canProceedStep2)"
              @click="step++"
            >Next →</button>
          </template>
          <template v-else>
            <button class="btn-create" :disabled="saving" @click="createTenant">
              {{ saving ? 'Creating…' : 'Create Tenant' }}
            </button>
          </template>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.wizard-backdrop {
  position: fixed; inset: 0; background: rgba(0,0,0,0.4);
  display: flex; align-items: center; justify-content: center;
  z-index: 1000;
}

.wizard-modal {
  background: #fff; border-radius: 12px; width: 440px; max-width: 95vw;
  box-shadow: 0 8px 40px rgba(0,0,0,0.18);
  display: flex; flex-direction: column;
  max-height: 90vh; overflow: hidden;
}

.wizard-header {
  display: flex; align-items: center; padding: 16px 20px 12px;
  border-bottom: 1px solid #f1f5f9;
}
.wizard-steps { display: flex; gap: 8px; flex: 1; }
.step-dot {
  width: 24px; height: 24px; border-radius: 50%; border: 2px solid #e2e8f0;
  display: flex; align-items: center; justify-content: center;
  font-size: 11px; font-weight: 700; color: #94a3b8; background: #fff;
}
.step-dot.active { border-color: #93c5fd; background: #eff6ff; color: #3b82f6; }
.step-dot.current { border-color: #3b82f6; background: #3b82f6; color: #fff; }

.close-btn {
  background: none; border: none; cursor: pointer; color: #94a3b8;
  font-size: 14px; padding: 4px 6px; border-radius: 4px;
}
.close-btn:hover { background: #f1f5f9; }

.wizard-body { padding: 20px; display: flex; flex-direction: column; gap: 14px; overflow-y: auto; flex: 1; }
.wizard-body--tall { flex: 1; min-height: 320px; }

.step-title { font-size: 16px; font-weight: 700; color: #0f172a; margin: 0; }
.step-desc { font-size: 13px; color: #64748b; margin: 0; }

.field-group { display: flex; flex-direction: column; gap: 4px; }
.field-group label {
  font-size: 11px; font-weight: 700; color: #64748b;
  text-transform: uppercase; letter-spacing: 0.04em;
  display: flex; align-items: center; gap: 8px;
}
.hint { font-size: 10px; color: #94a3b8; text-transform: none; font-weight: 400; }

.form-input {
  border: 1px solid #e2e8f0; border-radius: 6px; padding: 7px 10px;
  font-size: 13px; color: #0f172a; background: #fff; width: 100%; box-sizing: border-box;
}
.form-input:focus { outline: none; border-color: #3b82f6; }

.id-row { display: flex; gap: 8px; }
.btn-validate {
  background: #f1f5f9; border: 1px solid #e2e8f0; border-radius: 6px;
  padding: 7px 14px; font-size: 13px; cursor: pointer; white-space: nowrap;
  flex-shrink: 0;
}
.btn-validate:hover:not(:disabled) { background: #e2e8f0; }
.btn-validate:disabled { opacity: 0.5; cursor: default; }

.field-error { font-size: 12px; color: #dc2626; }
.field-ok { font-size: 12px; color: #16a34a; }

.summary-table { display: flex; flex-direction: column; gap: 6px; background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; }
.summary-row { display: flex; justify-content: space-between; align-items: center; font-size: 13px; }
.summary-row span { color: #64748b; }
.summary-row strong { color: #0f172a; }

.wizard-footer {
  display: flex; align-items: center; padding: 12px 20px 16px;
  border-top: 1px solid #f1f5f9; gap: 8px;
}
.spacer { flex: 1; }

.btn-back {
  background: none; border: 1px solid #e2e8f0; border-radius: 6px;
  padding: 7px 14px; font-size: 13px; cursor: pointer; color: #475569;
}
.btn-back:hover { background: #f1f5f9; }
.btn-next {
  background: #3b82f6; color: #fff; border: none; border-radius: 6px;
  padding: 7px 20px; font-size: 13px; font-weight: 600; cursor: pointer;
}
.btn-next:hover:not(:disabled) { background: #2563eb; }
.btn-next:disabled { opacity: 0.5; cursor: default; }
.btn-create {
  background: #16a34a; color: #fff; border: none; border-radius: 6px;
  padding: 7px 20px; font-size: 13px; font-weight: 600; cursor: pointer;
}
.btn-create:hover:not(:disabled) { background: #15803d; }
.btn-create:disabled { opacity: 0.5; cursor: default; }
</style>
