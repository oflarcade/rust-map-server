<script setup lang="ts">
import { ref, onMounted, watch, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from '../composables/useTileInspector';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import Checkbox from 'primevue/checkbox';
import Accordion from 'primevue/accordion';
import AccordionPanel from 'primevue/accordionpanel';
import AccordionHeader from 'primevue/accordionheader';
import AccordionContent from 'primevue/accordioncontent';

const { selectedTenantId, loadHierarchy } = useTileInspector();
const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

const open = ref(false);
const loading = ref(false);
const inScope = ref<any[]>([]);
const available = ref<any[]>([]);
const searchQ = ref('');
const adding = ref(false);
const deleting = ref<string | null>(null);
const selectedAvailable = ref<string[]>([]);

async function loadTerritories() {
  loading.value = true;
  try {
    const res = await fetch(`${BASE}/admin/territories`, {
      headers: { 'X-Tenant-ID': selectedTenantId.value },
    });
    if (res.ok) {
      const data = await res.json();
      inScope.value = data.in_scope ?? [];
      available.value = data.available ?? [];
    }
  } catch { /* ignore */ } finally {
    loading.value = false;
  }
}

async function addPcode(pcode: string) {
  adding.value = true;
  try {
    await fetch(`${BASE}/admin/territories`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': selectedTenantId.value },
      body: JSON.stringify({ pcodes: [pcode] }),
    });
    await loadTerritories();
    loadHierarchy();
  } catch { /* ignore */ } finally {
    adding.value = false;
  }
}

async function addSelected() {
  if (selectedAvailable.value.length === 0) return;
  adding.value = true;
  try {
    await fetch(`${BASE}/admin/territories`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': selectedTenantId.value },
      body: JSON.stringify({ pcodes: selectedAvailable.value }),
    });
    selectedAvailable.value = [];
    await loadTerritories();
    loadHierarchy();
  } catch { /* ignore */ } finally {
    adding.value = false;
  }
}

async function removePcode(pcode: string) {
  deleting.value = pcode;
  try {
    await fetch(`${BASE}/admin/territories/${pcode}`, {
      method: 'DELETE',
      headers: { 'X-Tenant-ID': selectedTenantId.value },
    });
    await loadTerritories();
    loadHierarchy();
  } catch { /* ignore */ } finally {
    deleting.value = null;
  }
}

const filteredAvailable = computed(() => {
  const q = searchQ.value.toLowerCase().trim();
  if (!q) return available.value;
  return available.value.filter((f) =>
    f.name?.toLowerCase().includes(q) || f.pcode?.toLowerCase().includes(q),
  );
});

// Group available by state name
const availableByState = computed(() => {
  const groups: Record<string, any[]> = {};
  for (const f of filteredAvailable.value) {
    const key = f.parent_name || f.parent_pcode || 'Other';
    if (!groups[key]) groups[key] = [];
    groups[key].push(f);
  }
  return Object.entries(groups).sort((a, b) => a[0].localeCompare(b[0]));
});

watch(open, (val) => { if (val && inScope.value.length === 0) loadTerritories(); });
watch(selectedTenantId, () => { inScope.value = []; available.value = []; selectedAvailable.value = []; if (open.value) loadTerritories(); });
</script>

<template>
  <div class="border-t border-slate-200 mt-1.5">
    <Accordion>
      <AccordionPanel value="territories">
        <AccordionHeader class="!text-xs !font-semibold !text-slate-700">
          Territory Scope
          <span
            v-if="inScope.length > 0"
            class="ml-auto bg-sky-100 text-sky-600 text-[11px] font-bold px-1.5 py-0.5 rounded-full"
          >{{ inScope.length }}</span>
        </AccordionHeader>

        <AccordionContent>
          <div class="flex flex-col gap-1 py-1">
            <!-- Loading -->
            <div v-if="loading" class="text-xs text-slate-400">Loading…</div>

            <template v-else>
              <!-- In-scope list -->
              <div class="text-[10px] uppercase tracking-wider text-slate-500 mb-0.5 font-bold">
                In scope ({{ inScope.length }})
              </div>
              <div class="max-h-[120px] overflow-y-auto border border-slate-200 rounded-md bg-white">
                <div
                  v-for="f in inScope"
                  :key="f.pcode"
                  class="flex items-center gap-1.5 px-2 py-1 text-xs border-b border-slate-100 last:border-b-0"
                >
                  <span class="flex-1 text-slate-800 min-w-0 truncate">{{ f.name }}</span>
                  <span class="text-[10px] text-slate-400 shrink-0">{{ f.pcode }}</span>
                  <Button
                    icon="pi pi-trash"
                    size="small"
                    variant="text"
                    severity="danger"
                    :disabled="deleting === f.pcode"
                    @click="removePcode(f.pcode)"
                  />
                </div>
                <div v-if="inScope.length === 0" class="px-2 py-2 text-xs text-slate-400 text-center">
                  None in scope
                </div>
              </div>

              <!-- Available to add -->
              <div class="text-[10px] uppercase tracking-wider text-slate-500 mt-2 mb-0.5 font-bold">
                Available to add
              </div>
              <InputText
                v-model="searchQ"
                placeholder="Search available…"
                class="w-full !text-sm"
              />
              <div class="max-h-[160px] overflow-y-auto border border-slate-200 rounded-md bg-white mt-1">
                <template v-for="[stateName, lgas] in availableByState" :key="stateName">
                  <div class="text-[10px] uppercase tracking-wider text-slate-500 mt-2 mb-0.5 px-2 py-1 bg-slate-50 border-b border-slate-200 font-bold">
                    {{ stateName }}
                  </div>
                  <div
                    v-for="lga in lgas"
                    :key="lga.pcode"
                    class="flex items-center gap-2 px-2 py-1 text-xs border-b border-slate-100 last:border-b-0"
                  >
                    <Checkbox
                      v-model="selectedAvailable"
                      :value="lga.pcode"
                      :inputId="lga.pcode"
                    />
                    <label :for="lga.pcode" class="flex-1 text-slate-800 min-w-0 truncate cursor-pointer">
                      {{ lga.name }}
                    </label>
                    <span class="text-[10px] text-slate-400 shrink-0">{{ lga.pcode }}</span>
                  </div>
                </template>
                <div v-if="availableByState.length === 0" class="px-2 py-2 text-xs text-slate-400 text-center">
                  No results
                </div>
              </div>
              <Button
                label="Add Selected"
                icon="pi pi-plus"
                size="small"
                class="w-full mt-2"
                :disabled="adding || selectedAvailable.length === 0"
                @click="addSelected()"
              />
            </template>
          </div>
        </AccordionContent>
      </AccordionPanel>
    </Accordion>
  </div>
</template>
