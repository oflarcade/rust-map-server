<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue';
import InputText from 'primevue/inputtext';
import ColorPicker from 'primevue/colorpicker';
import Select from 'primevue/select';
import Chip from 'primevue/chip';
import Message from 'primevue/message';
import Button from 'primevue/button';
import { useToast } from 'primevue/usetoast';

const toast = useToast();

interface Props {
  tenantId: string;
  baseUrl: string;
  zoneTypes?: string[];
}

const props = defineProps<Props>();
const emit = defineEmits<{ (e: 'zone-created'): void }>();

// ── State ──────────────────────────────────────────────────────────────────
const hierarchyData = ref<any>(null);
const existingZones = ref<any[]>([]);
const loading = ref(false);
const loadError = ref('');
const status = ref('');
const statusType = ref<'info' | 'success' | 'error'>('info');

// Checked pcodes and their metadata
const selectedPcodes = ref<string[]>([]);
const selectedMeta = ref<Record<string, { name: string; isZone: boolean; parentPcode?: string }>>({});
const expandedNodes = ref(new Set<string>());

// Form fields
const zoneName = ref('');
const zoneType = ref('');
const zoneColor = ref('#10b981');
// ColorPicker uses hex WITHOUT '#'
const colorHex = computed({
  get: () => zoneColor.value.replace('#', ''),
  set: (v: string) => { zoneColor.value = '#' + v; },
});
const parentPcode = ref('');
const childrenType = ref<'lga' | 'zone'>('lga');

const DEFAULT_COLORS = ['#10b981', '#f59e0b', '#3b82f6', '#a78bfa', '#f43f5e'];

// ── Data loading ────────────────────────────────────────────────────────────
async function loadData() {
  loading.value = true;
  loadError.value = '';
  try {
    const tid = props.tenantId;
    const [hierRes, zonesRes] = await Promise.all([
      fetch(`${props.baseUrl}/boundaries/hierarchy?t=${tid}`, { headers: { 'X-Tenant-ID': tid } }),
      fetch(`${props.baseUrl}/admin/zones`, { headers: { 'X-Tenant-ID': tid } }),
    ]);
    if (hierRes.ok) hierarchyData.value = await hierRes.json();
    if (zonesRes.ok) {
      const data = await zonesRes.json();
      existingZones.value = data.zones ?? [];
    }
  } catch (e: any) {
    loadError.value = e.message;
  } finally {
    loading.value = false;
  }
}

// ── Tree helpers ────────────────────────────────────────────────────────────
function toggleNode(pcode: string) {
  if (expandedNodes.value.has(pcode)) expandedNodes.value.delete(pcode);
  else expandedNodes.value.add(pcode);
  expandedNodes.value = new Set(expandedNodes.value);
}

function isExpanded(pcode: string) { return expandedNodes.value.has(pcode); }
function isSelected(pcode: string) { return selectedPcodes.value.includes(pcode); }

function togglePcode(pcode: string, name: string, isZone: boolean, parentPcodeVal?: string) {
  const idx = selectedPcodes.value.indexOf(pcode);
  if (idx >= 0) {
    selectedPcodes.value.splice(idx, 1);
    delete selectedMeta.value[pcode];
  } else {
    selectedPcodes.value.push(pcode);
    selectedMeta.value[pcode] = { name, isZone, parentPcode: parentPcodeVal };
  }
  updateAutoDetect();
}

function removePcode(pcode: string) {
  const idx = selectedPcodes.value.indexOf(pcode);
  if (idx >= 0) {
    selectedPcodes.value.splice(idx, 1);
    delete selectedMeta.value[pcode];
  }
  updateAutoDetect();
}

function selectAllChildren(stateNode: any) {
  const toAdd: Array<{ pcode: string; name: string; isZone: boolean; parent: string }> = [];
  if (stateNode.children?.length) {
    for (const child of stateNode.children) {
      const pcode = child.zone_pcode ?? child.pcode;
      const name = child.zone_name ?? child.name;
      toAdd.push({ pcode, name, isZone: !!(child.zone_pcode), parent: stateNode.pcode });
    }
  } else {
    for (const lga of stateNode.lgas ?? []) {
      toAdd.push({ pcode: lga.pcode, name: lga.name, isZone: false, parent: stateNode.pcode });
    }
  }
  for (const item of toAdd) {
    if (!isSelected(item.pcode)) {
      selectedPcodes.value.push(item.pcode);
      selectedMeta.value[item.pcode] = { name: item.name, isZone: item.isZone, parentPcode: item.parent };
    }
  }
  updateAutoDetect();
}

// ── Auto-detect parent + children_type ─────────────────────────────────────
function updateAutoDetect() {
  const metas = Object.values(selectedMeta.value);
  if (metas.length === 0) { parentPcode.value = ''; childrenType.value = 'lga'; return; }

  const hasZones = metas.some(m => m.isZone);
  const hasLgas  = metas.some(m => !m.isZone);
  childrenType.value = (hasZones && !hasLgas) ? 'zone' : 'lga';

  const parents = [...new Set(metas.map(m => m.parentPcode).filter(Boolean))];
  if (parents.length === 1) parentPcode.value = parents[0]!;
  else if (parents.length > 1) parentPcode.value = '';
}

// ── Computed ────────────────────────────────────────────────────────────────
const parentOptions = computed(() => {
  const opts: Array<{ pcode: string; label: string }> = [];
  if (!hierarchyData.value) return opts;
  for (const state of hierarchyData.value.states ?? [])
    opts.push({ pcode: state.pcode, label: `${state.name} (State)` });
  for (const z of existingZones.value)
    opts.push({ pcode: z.zone_pcode, label: `${'  '.repeat(z.zone_level)}${z.zone_name} (L${z.zone_level})` });
  return opts;
});

const zoneLevel = computed(() => {
  const pz = existingZones.value.find(z => z.zone_pcode === parentPcode.value);
  return pz ? pz.zone_level + 1 : 1;
});

const mixedSelection = computed(() => {
  const metas = Object.values(selectedMeta.value);
  return metas.some(m => m.isZone) && metas.some(m => !m.isZone);
});

watch(zoneLevel, (lvl) => {
  zoneColor.value = DEFAULT_COLORS[Math.min(lvl - 1, DEFAULT_COLORS.length - 1)];
});

// ── Form submit ─────────────────────────────────────────────────────────────
function setStatus(msg: string, type: 'info' | 'success' | 'error' = 'info') {
  status.value = msg; statusType.value = type;
}

async function handleSave() {
  if (!zoneName.value.trim())            { setStatus('Zone name is required', 'error'); return; }
  if (selectedPcodes.value.length === 0) { setStatus('Select at least one item from the tree', 'error'); return; }
  if (!parentPcode.value)                { setStatus('Could not determine parent — choose one manually', 'error'); return; }
  if (mixedSelection.value)             { setStatus('Selection mixes zones and LGAs — pick one type only', 'error'); return; }

  const body: Record<string, any> = {
    zone_name:          zoneName.value.trim(),
    color:              zoneColor.value,
    parent_pcode:       parentPcode.value,
    constituent_pcodes: selectedPcodes.value,
    zone_level:         zoneLevel.value,
    children_type:      childrenType.value,
  };
  if (zoneType.value.trim()) body.zone_type_label = zoneType.value.trim();

  setStatus('Creating zone…');
  try {
    const res = await fetch(`${props.baseUrl}/admin/zones`, {
      method: 'POST',
      headers: { 'X-Tenant-ID': props.tenantId, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? res.statusText);
    setStatus(`Zone "${data.zone_name}" created (${data.zone_pcode})`, 'success');
    toast.add({ severity: 'success', summary: 'Zone saved', life: 3000 });
    clearForm();
    await loadData();
    emit('zone-created');
  } catch (e: any) {
    setStatus(`Create failed: ${e.message}`, 'error');
    toast.add({ severity: 'error', summary: 'Failed to save', detail: e.message, life: 4000 });
  }
}

function clearForm() {
  zoneName.value = '';
  zoneType.value = '';
  zoneColor.value = DEFAULT_COLORS[0];
  parentPcode.value = '';
  selectedPcodes.value = [];
  selectedMeta.value = {};
  childrenType.value = 'lga';
  status.value = '';
}

watch(() => props.tenantId, () => { clearForm(); loadData(); });
onMounted(() => loadData());
</script>

<template>
  <div class="flex flex-col h-full min-h-0">
    <div v-if="loading" class="p-4 text-slate-500 text-sm">Loading hierarchy…</div>
    <div v-else-if="loadError" class="p-4 text-red-600 text-sm">{{ loadError }}</div>
    <div v-else class="flex flex-1 min-h-0">

      <!-- Left: tree with checkboxes -->
      <div class="flex-1 overflow-y-auto border-r border-slate-200 p-2.5 min-w-0">
        <div class="text-[10px] font-bold uppercase tracking-wider text-slate-500 mb-2 pb-1.5 border-b border-slate-200">
          Select Constituents
        </div>
        <div v-if="hierarchyData" class="text-xs">
          <div v-for="state in hierarchyData.states" :key="state.pcode" class="mb-0.5">
            <!-- State header row -->
            <div class="flex items-center gap-1 py-0.5">
              <button
                class="bg-transparent border-none cursor-pointer text-slate-400 text-[11px] px-0.5 leading-none"
                @click="toggleNode(state.pcode)"
              >{{ isExpanded(state.pcode) ? '▾' : '▸' }}</button>
              <button
                class="bg-blue-50 border-none cursor-pointer text-blue-700 text-[10px] px-1.5 py-px rounded flex-shrink-0"
                title="Select all"
                @click="selectAllChildren(state)"
              >+all</button>
              <span class="font-semibold text-sky-700 flex-1">{{ state.name }}</span>
            </div>

            <div v-if="isExpanded(state.pcode)" class="ml-3.5">
              <!-- Variable-depth zone/adm-feature children -->
              <template v-if="state.children?.length">
                <div v-for="child in state.children" :key="child.zone_pcode ?? child.pcode" class="flex flex-col">
                  <label
                    class="flex items-center gap-1.5 px-1 py-0.5 rounded cursor-pointer text-[11px] hover:bg-slate-100"
                    :class="child.zone_pcode ? 'text-blue-800' : 'text-slate-700'"
                  >
                    <input
                      type="checkbox"
                      class="flex-shrink-0 accent-blue-600"
                      :checked="isSelected(child.zone_pcode ?? child.pcode)"
                      @change="togglePcode(child.zone_pcode ?? child.pcode, child.zone_name ?? child.name, !!(child.zone_pcode), state.pcode)"
                    />
                    <span v-if="child.zone_pcode" class="w-2 h-2 rounded-full flex-shrink-0" :style="{ background: child.color ?? '#a78bfa' }"></span>
                    <span v-if="child.zone_type_label" class="text-[9px] bg-slate-200 text-slate-600 rounded px-1 flex-shrink-0 whitespace-nowrap">{{ child.zone_type_label }}</span>
                    <span class="flex-1 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">{{ child.zone_name ?? child.name }}</span>
                    <button
                      v-if="child.children?.length"
                      class="bg-transparent border-none cursor-pointer text-slate-400 text-[11px] px-0.5 leading-none ml-auto flex-shrink-0"
                      @click.prevent="toggleNode(child.zone_pcode ?? child.pcode)"
                    >{{ isExpanded(child.zone_pcode ?? child.pcode) ? '▾' : '▸' }}</button>
                  </label>
                  <!-- Level-2 children -->
                  <div v-if="isExpanded(child.zone_pcode ?? child.pcode) && child.children?.length" class="ml-3.5">
                    <div v-for="z2 in child.children" :key="z2.zone_pcode ?? z2.pcode" class="flex flex-col">
                      <label
                        class="flex items-center gap-1.5 px-1 py-0.5 rounded cursor-pointer text-[11px] hover:bg-slate-100"
                        :class="z2.zone_pcode ? 'text-blue-800' : 'text-slate-700'"
                      >
                        <input
                          type="checkbox"
                          class="flex-shrink-0 accent-blue-600"
                          :checked="isSelected(z2.zone_pcode ?? z2.pcode)"
                          @change="togglePcode(z2.zone_pcode ?? z2.pcode, z2.zone_name ?? z2.name, !!(z2.zone_pcode), child.zone_pcode ?? child.pcode)"
                        />
                        <span v-if="z2.zone_pcode" class="w-2 h-2 rounded-full flex-shrink-0" :style="{ background: z2.color ?? '#a78bfa' }"></span>
                        <span v-if="z2.zone_type_label" class="text-[9px] bg-slate-200 text-slate-600 rounded px-1 flex-shrink-0 whitespace-nowrap">{{ z2.zone_type_label }}</span>
                        <span class="flex-1 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">{{ z2.zone_name ?? z2.name }}</span>
                        <button
                          v-if="z2.children?.length"
                          class="bg-transparent border-none cursor-pointer text-slate-400 text-[11px] px-0.5 leading-none ml-auto flex-shrink-0"
                          @click.prevent="toggleNode(z2.zone_pcode ?? z2.pcode)"
                        >{{ isExpanded(z2.zone_pcode ?? z2.pcode) ? '▾' : '▸' }}</button>
                      </label>
                      <!-- Level-3 children -->
                      <div v-if="isExpanded(z2.zone_pcode ?? z2.pcode) && z2.children?.length" class="ml-3.5">
                        <label
                          v-for="z3 in z2.children" :key="z3.zone_pcode ?? z3.pcode"
                          class="flex items-center gap-1.5 px-1 py-0.5 rounded cursor-pointer text-[11px] hover:bg-slate-100"
                          :class="z3.zone_pcode ? 'text-blue-800' : 'text-slate-700'"
                        >
                          <input
                            type="checkbox"
                            class="flex-shrink-0 accent-blue-600"
                            :checked="isSelected(z3.zone_pcode ?? z3.pcode)"
                            @change="togglePcode(z3.zone_pcode ?? z3.pcode, z3.zone_name ?? z3.name, !!(z3.zone_pcode), z2.zone_pcode ?? z2.pcode)"
                          />
                          <span v-if="z3.zone_pcode" class="w-2 h-2 rounded-full flex-shrink-0" :style="{ background: z3.color ?? '#3b82f6' }"></span>
                          <span v-if="z3.zone_type_label" class="text-[9px] bg-slate-200 text-slate-600 rounded px-1 flex-shrink-0 whitespace-nowrap">{{ z3.zone_type_label }}</span>
                          <span class="flex-1 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">{{ z3.zone_name ?? z3.name }}</span>
                        </label>
                      </div>
                    </div>
                  </div>
                </div>
              </template>
              <!-- Flat LGAs (no zone hierarchy yet) -->
              <template v-else>
                <label
                  v-for="lga in state.lgas" :key="lga.pcode"
                  class="flex items-center gap-1.5 px-1 py-0.5 rounded cursor-pointer text-[11px] text-slate-700 hover:bg-slate-100"
                >
                  <input
                    type="checkbox"
                    class="flex-shrink-0 accent-blue-600"
                    :checked="isSelected(lga.pcode)"
                    @change="togglePcode(lga.pcode, lga.name, false, state.pcode)"
                  />
                  <span v-if="lga.level_label" class="text-[9px] bg-slate-200 text-slate-600 rounded px-1 flex-shrink-0 whitespace-nowrap">{{ lga.level_label }}</span>
                  <span class="flex-1 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap">{{ lga.name }}</span>
                </label>
              </template>
            </div>
          </div>
        </div>
        <div v-else class="text-slate-400 text-xs py-2.5">No hierarchy data available.</div>
      </div>

      <!-- Right: form panel -->
      <div class="w-[260px] flex-shrink-0 overflow-y-auto p-2.5 flex flex-col gap-2.5">
        <div class="text-[10px] font-bold uppercase tracking-wider text-slate-500 mb-0 pb-1.5 border-b border-slate-200">
          Zone Details
        </div>

        <!-- Selected chips -->
        <div class="flex flex-col gap-1">
          <label class="text-[10px] font-bold uppercase tracking-wider text-slate-500">
            Selected
            <span class="bg-blue-100 text-blue-700 rounded-full px-1.5 py-px text-[10px] ml-1">{{ selectedPcodes.length }}</span>
          </label>
          <div v-if="selectedPcodes.length > 0" class="flex flex-wrap gap-1 max-h-24 overflow-y-auto">
            <Chip
              v-for="p in selectedPcodes" :key="p"
              :label="selectedMeta[p]?.name ?? p"
              removable
              class="text-xs"
              @remove="removePcode(p)"
            />
          </div>
          <div v-else class="text-[11px] text-slate-400 italic">Tick items in the tree</div>
          <div v-if="mixedSelection" class="text-[11px] text-amber-600">⚠ Mixed zones + LGAs — select one type only</div>
        </div>

        <div class="flex flex-col gap-1">
          <label class="text-[10px] font-bold uppercase tracking-wider text-slate-500">Type detected</label>
          <div class="text-xs text-slate-600 bg-slate-100 rounded px-2 py-1">{{ childrenType === 'zone' ? 'Child zones' : 'LGAs / Adm features' }}</div>
        </div>

        <!-- Zone Name -->
        <div class="flex flex-col gap-1">
          <label class="text-[10px] font-bold uppercase tracking-wider text-slate-500">Zone Name</label>
          <InputText v-model="zoneName" placeholder="e.g. Hadejia Emirate" class="w-full" />
        </div>

        <!-- Zone Type -->
        <div class="flex flex-col gap-1">
          <label class="text-[10px] font-bold uppercase tracking-wider text-slate-500">Zone Type</label>
          <Select
            v-if="props.zoneTypes?.length"
            v-model="zoneType"
            :options="props.zoneTypes"
            showClear
            placeholder="— none —"
            class="w-full"
          />
          <InputText v-else v-model="zoneType" placeholder="e.g. Cluster (optional)" class="w-full" />
        </div>

        <!-- Color -->
        <div class="flex flex-col gap-1">
          <label class="text-[10px] font-bold uppercase tracking-wider text-slate-500">Color</label>
          <div class="flex items-center gap-2">
            <ColorPicker v-model="colorHex" format="hex" />
            <span class="text-xs text-slate-500">{{ zoneColor }}</span>
          </div>
        </div>

        <!-- Parent -->
        <div class="flex flex-col gap-1">
          <label class="text-[10px] font-bold uppercase tracking-wider text-slate-500">Parent</label>
          <Select
            v-model="parentPcode"
            :options="parentOptions"
            optionValue="pcode"
            optionLabel="label"
            showClear
            placeholder="— auto-detected —"
            class="w-full"
          />
          <div v-if="!parentPcode && selectedPcodes.length > 0" class="text-[11px] text-amber-600">
            Items have different parents — select one manually
          </div>
        </div>

        <!-- Status message -->
        <Message
          v-if="status"
          :severity="statusType === 'error' ? 'error' : statusType === 'success' ? 'success' : 'info'"
          class="mt-2"
        >{{ status }}</Message>

        <!-- Actions -->
        <div class="flex gap-2">
          <Button label="Save Zone" icon="pi pi-check" class="w-full" @click="handleSave()" />
          <Button label="Clear" variant="outlined" severity="secondary" @click="clearForm()" />
        </div>

      </div>
    </div>
  </div>
</template>
