<script setup lang="ts">
import { ref, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from '../composables/useTileInspector';
import WizardStep3States from './WizardStep3States.vue';
import Dialog from 'primevue/dialog';
import Stepper from 'primevue/stepper';
import StepList from 'primevue/steplist';
import Step from 'primevue/step';
import InputText from 'primevue/inputtext';
import Select from 'primevue/select';
import Button from 'primevue/button';
import Message from 'primevue/message';

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
  <Dialog
    :visible="true"
    modal
    header="Add New Tenant"
    :closable="true"
    @update:visible="(v) => !v && emit('close')"
    class="w-full max-w-xl"
    :pt="{ content: { class: 'p-0' } }"
  >
    <div class="flex flex-col">
      <!-- Step indicator -->
      <div class="px-5 pt-4 pb-2">
        <Stepper :value="step" linear class="mb-2">
          <StepList>
            <Step :value="1">Tenant ID</Step>
            <Step :value="2">Country &amp; Tiles</Step>
            <Step :value="3">Scope</Step>
            <Step :value="4">Review</Step>
          </StepList>
        </Stepper>
      </div>

      <!-- Step 1: Tenant ID -->
      <div v-if="step === 1" class="px-5 py-4 flex flex-col gap-4">
        <div>
          <p class="text-base font-bold text-slate-900 mb-1">Choose Tenant ID</p>
          <p class="text-sm text-slate-500">Enter a unique numeric ID for the new tenant.</p>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-bold text-slate-500 uppercase tracking-wide">Tenant ID</label>
          <div class="flex gap-2">
            <InputText
              v-model="tenantId"
              type="number"
              placeholder="e.g. 20"
              class="w-full"
              @input="idValid = false; idError = ''"
              @keyup.enter="validateId"
            />
            <Button
              label="Check"
              :loading="idValidating"
              variant="outlined"
              @click="validateId"
            />
          </div>
          <Message v-if="idError" severity="error" class="mt-1">{{ idError }}</Message>
          <p v-if="idValid" class="text-sm text-green-600 mt-1">
            <i class="pi pi-check-circle mr-1" />ID {{ tenantId }} is available
          </p>
        </div>
      </div>

      <!-- Step 2: Country + Name + Sources -->
      <div v-else-if="step === 2" class="px-5 py-4 flex flex-col gap-4">
        <p class="text-base font-bold text-slate-900">Country &amp; Tile Sources</p>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-bold text-slate-500 uppercase tracking-wide">Country</label>
          <Select
            v-model="countryCode"
            :options="COUNTRY_OPTIONS"
            optionValue="value"
            optionLabel="label"
            placeholder="— select —"
            class="w-full"
            @change="onCountryChange"
          />
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-bold text-slate-500 uppercase tracking-wide">Tenant name</label>
          <InputText v-model="tenantName" placeholder="e.g. Bridge Tanzania" class="w-full" />
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-bold text-slate-500 uppercase tracking-wide flex items-center gap-2">
            Tile source
            <span v-if="hintSrc" class="text-xs text-slate-400 normal-case font-normal">{{ hintSrc.tile }}</span>
          </label>
          <InputText v-model="tileSource" placeholder="e.g. kenya-detailed" class="w-full" />
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-bold text-slate-500 uppercase tracking-wide flex items-center gap-2">
            Boundary source
            <span v-if="hintSrc" class="text-xs text-slate-400 normal-case font-normal">{{ hintSrc.boundary }}</span>
          </label>
          <InputText v-model="boundarySource" placeholder="e.g. kenya-boundaries" class="w-full" />
        </div>
      </div>

      <!-- Step 3: States / LGAs tree -->
      <div v-else-if="step === 3" class="px-5 py-4 flex flex-col gap-3" style="min-height: 360px;">
        <div>
          <p class="text-base font-bold text-slate-900 mb-1">Select States &amp; LGAs</p>
          <p class="text-sm text-slate-500">Choose which LGAs this tenant operates in (optional).</p>
        </div>
        <WizardStep3States
          :country-code="countryCode"
          :selected="selectedPcodes"
          @update:selected="selectedPcodes = $event"
        />
      </div>

      <!-- Step 4: Summary -->
      <div v-else-if="step === 4" class="px-5 py-4 flex flex-col gap-4">
        <p class="text-base font-bold text-slate-900">Review &amp; Create</p>
        <div class="flex flex-col gap-1.5 bg-slate-50 border border-slate-200 rounded-lg p-3">
          <div class="flex justify-between items-center text-sm">
            <span class="text-slate-500">Tenant ID</span>
            <strong class="text-slate-900">{{ tenantId }}</strong>
          </div>
          <div class="flex justify-between items-center text-sm">
            <span class="text-slate-500">Country</span>
            <strong class="text-slate-900">{{ countryCode }}</strong>
          </div>
          <div class="flex justify-between items-center text-sm">
            <span class="text-slate-500">Name</span>
            <strong class="text-slate-900">{{ tenantName }}</strong>
          </div>
          <div class="flex justify-between items-center text-sm">
            <span class="text-slate-500">Tile source</span>
            <strong class="text-slate-900">{{ tileSource }}</strong>
          </div>
          <div class="flex justify-between items-center text-sm">
            <span class="text-slate-500">Boundary source</span>
            <strong class="text-slate-900">{{ boundarySource }}</strong>
          </div>
          <div class="flex justify-between items-center text-sm">
            <span class="text-slate-500">LGAs in scope</span>
            <strong class="text-slate-900">{{ selectedPcodes.length }}</strong>
          </div>
        </div>
        <Message v-if="errorMsg" severity="error">{{ errorMsg }}</Message>
      </div>

      <!-- Footer -->
      <div class="flex items-center gap-2 px-5 py-3 border-t border-slate-100">
        <Button
          v-if="step > 1"
          label="Back"
          icon="pi pi-arrow-left"
          variant="outlined"
          @click="step--"
        />
        <span class="flex-1" />
        <template v-if="step < 4">
          <Button
            label="Next"
            icon="pi pi-arrow-right"
            iconPos="right"
            :disabled="(step === 1 && !canProceedStep1) || (step === 2 && !canProceedStep2)"
            @click="step++"
          />
        </template>
        <template v-else>
          <Button
            label="Create Tenant"
            icon="pi pi-check"
            severity="success"
            :loading="saving"
            @click="createTenant"
          />
        </template>
      </div>
    </div>
  </Dialog>
</template>
