<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue';

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

async function submitZone() {
  if (!zoneName.value.trim())       { setStatus('Zone name is required', 'error'); return; }
  if (selectedPcodes.value.length === 0) { setStatus('Select at least one item from the tree', 'error'); return; }
  if (!parentPcode.value)           { setStatus('Could not determine parent — choose one manually', 'error'); return; }
  if (mixedSelection.value)         { setStatus('Selection mixes zones and LGAs — pick one type only', 'error'); return; }

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
    clearForm();
    await loadData();
    emit('zone-created');
  } catch (e: any) {
    setStatus(`Create failed: ${e.message}`, 'error');
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
  <div class="zcp-root">
    <div v-if="loading" class="zcp-loading">Loading hierarchy…</div>
    <div v-else-if="loadError" class="zcp-err">{{ loadError }}</div>
    <div v-else class="zcp-body">

      <!-- Left: tree with checkboxes -->
      <div class="zcp-tree-col">
        <div class="zcp-col-head">Select Constituents</div>
        <div v-if="hierarchyData" class="zcp-tree">
          <div v-for="state in hierarchyData.states" :key="state.pcode" class="zcp-state-group">
            <!-- State header row -->
            <div class="zcp-state-row">
              <button class="zcp-arrow" @click="toggleNode(state.pcode)">
                {{ isExpanded(state.pcode) ? '▾' : '▸' }}
              </button>
              <button class="zcp-all-btn" @click="selectAllChildren(state)" title="Select all">+all</button>
              <span class="zcp-state-name">{{ state.name }}</span>
            </div>

            <div v-if="isExpanded(state.pcode)" class="zcp-children">
              <!-- Variable-depth zone/adm-feature children -->
              <template v-if="state.children?.length">
                <div v-for="child in state.children" :key="child.zone_pcode ?? child.pcode" class="zcp-node-group">
                  <label class="zcp-item" :class="{ 'zcp-item-zone': child.zone_pcode }">
                    <input
                      type="checkbox"
                      :checked="isSelected(child.zone_pcode ?? child.pcode)"
                      @change="togglePcode(child.zone_pcode ?? child.pcode, child.zone_name ?? child.name, !!(child.zone_pcode), state.pcode)"
                    />
                    <span v-if="child.zone_pcode" class="zcp-dot" :style="{ background: child.color ?? '#a78bfa' }"></span>
                    <span v-if="child.zone_type_label" class="zcp-tag">{{ child.zone_type_label }}</span>
                    <span class="zcp-item-name">{{ child.zone_name ?? child.name }}</span>
                    <button
                      v-if="child.children?.length"
                      class="zcp-arrow zcp-arrow-sm"
                      @click.prevent="toggleNode(child.zone_pcode ?? child.pcode)"
                    >{{ isExpanded(child.zone_pcode ?? child.pcode) ? '▾' : '▸' }}</button>
                  </label>
                  <!-- Level-2 children -->
                  <div v-if="isExpanded(child.zone_pcode ?? child.pcode) && child.children?.length" class="zcp-children zcp-l2">
                    <div v-for="z2 in child.children" :key="z2.zone_pcode ?? z2.pcode" class="zcp-node-group">
                      <label class="zcp-item" :class="{ 'zcp-item-zone': z2.zone_pcode }">
                        <input
                          type="checkbox"
                          :checked="isSelected(z2.zone_pcode ?? z2.pcode)"
                          @change="togglePcode(z2.zone_pcode ?? z2.pcode, z2.zone_name ?? z2.name, !!(z2.zone_pcode), child.zone_pcode ?? child.pcode)"
                        />
                        <span v-if="z2.zone_pcode" class="zcp-dot" :style="{ background: z2.color ?? '#a78bfa' }"></span>
                        <span v-if="z2.zone_type_label" class="zcp-tag">{{ z2.zone_type_label }}</span>
                        <span class="zcp-item-name">{{ z2.zone_name ?? z2.name }}</span>
                        <button
                          v-if="z2.children?.length"
                          class="zcp-arrow zcp-arrow-sm"
                          @click.prevent="toggleNode(z2.zone_pcode ?? z2.pcode)"
                        >{{ isExpanded(z2.zone_pcode ?? z2.pcode) ? '▾' : '▸' }}</button>
                      </label>
                      <!-- Level-3 children -->
                      <div v-if="isExpanded(z2.zone_pcode ?? z2.pcode) && z2.children?.length" class="zcp-children zcp-l3">
                        <label v-for="z3 in z2.children" :key="z3.zone_pcode ?? z3.pcode" class="zcp-item" :class="{ 'zcp-item-zone': z3.zone_pcode }">
                          <input
                            type="checkbox"
                            :checked="isSelected(z3.zone_pcode ?? z3.pcode)"
                            @change="togglePcode(z3.zone_pcode ?? z3.pcode, z3.zone_name ?? z3.name, !!(z3.zone_pcode), z2.zone_pcode ?? z2.pcode)"
                          />
                          <span v-if="z3.zone_pcode" class="zcp-dot" :style="{ background: z3.color ?? '#3b82f6' }"></span>
                          <span v-if="z3.zone_type_label" class="zcp-tag">{{ z3.zone_type_label }}</span>
                          <span class="zcp-item-name">{{ z3.zone_name ?? z3.name }}</span>
                        </label>
                      </div>
                    </div>
                  </div>
                </div>
              </template>
              <!-- Flat LGAs (no zone hierarchy yet) -->
              <template v-else>
                <label v-for="lga in state.lgas" :key="lga.pcode" class="zcp-item">
                  <input
                    type="checkbox"
                    :checked="isSelected(lga.pcode)"
                    @change="togglePcode(lga.pcode, lga.name, false, state.pcode)"
                  />
                  <span v-if="lga.level_label" class="zcp-tag">{{ lga.level_label }}</span>
                  <span class="zcp-item-name">{{ lga.name }}</span>
                </label>
              </template>
            </div>
          </div>
        </div>
        <div v-else class="zcp-empty">No hierarchy data available.</div>
      </div>

      <!-- Right: form panel -->
      <div class="zcp-form-col">
        <div class="zcp-col-head">Zone Details</div>

        <!-- Selected chips -->
        <div class="zcp-fg">
          <label class="zcp-label">Selected <span class="zcp-badge">{{ selectedPcodes.length }}</span></label>
          <div v-if="selectedPcodes.length > 0" class="zcp-chips">
            <span v-for="p in selectedPcodes" :key="p" class="zcp-chip">
              {{ selectedMeta[p]?.name ?? p }}
              <button @click="togglePcode(p, selectedMeta[p]?.name ?? p, selectedMeta[p]?.isZone ?? false)">×</button>
            </span>
          </div>
          <div v-else class="zcp-hint">Tick items in the tree</div>
          <div v-if="mixedSelection" class="zcp-warn">⚠ Mixed zones + LGAs — select one type only</div>
        </div>

        <div class="zcp-fg">
          <label class="zcp-label">Type detected</label>
          <div class="zcp-readonly">{{ childrenType === 'zone' ? 'Child zones' : 'LGAs / Adm features' }}</div>
        </div>

        <div class="zcp-fg">
          <label class="zcp-label">Zone Name</label>
          <input v-model="zoneName" type="text" class="zcp-input" placeholder="e.g. Hadejia Emirate" />
        </div>

        <div class="zcp-fg">
          <label class="zcp-label">Zone Type</label>
          <select v-if="props.zoneTypes?.length" v-model="zoneType" class="zcp-input">
            <option value="">— none —</option>
            <option v-for="t in props.zoneTypes" :key="t" :value="t">{{ t }}</option>
          </select>
          <input v-else v-model="zoneType" type="text" class="zcp-input" placeholder="e.g. Cluster (optional)" />
        </div>

        <div class="zcp-fg">
          <label class="zcp-label">Color</label>
          <div class="zcp-color-row">
            <input v-model="zoneColor" type="color" class="zcp-color-pick" />
            <span class="zcp-muted">{{ zoneColor }}</span>
          </div>
        </div>

        <div class="zcp-fg">
          <label class="zcp-label">Parent</label>
          <select v-model="parentPcode" class="zcp-input">
            <option value="">— auto-detected —</option>
            <option v-for="opt in parentOptions" :key="opt.pcode" :value="opt.pcode">{{ opt.label }}</option>
          </select>
          <div v-if="!parentPcode && selectedPcodes.length > 0" class="zcp-warn">
            Items have different parents — select one manually
          </div>
        </div>

        <div v-if="status" :class="['zcp-status', statusType]">{{ status }}</div>

        <div class="zcp-btn-row">
          <button class="zcp-btn zcp-btn-p" @click="submitZone">Create Zone</button>
          <button class="zcp-btn zcp-btn-s" @click="clearForm">Clear</button>
        </div>
      </div>

    </div>
  </div>
</template>

<style scoped>
.zcp-root { display: flex; flex-direction: column; height: 100%; min-height: 0; }
.zcp-loading { padding: 16px; color: #64748b; font-size: 13px; }
.zcp-err { padding: 16px; color: #dc2626; font-size: 13px; }
.zcp-body { display: flex; flex: 1; min-height: 0; }

/* Tree column */
.zcp-tree-col { flex: 1; overflow-y: auto; border-right: 1px solid #e2e8f0; padding: 10px; min-width: 0; }
.zcp-col-head { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: #64748b; margin-bottom: 8px; padding-bottom: 6px; border-bottom: 1px solid #e2e8f0; }
.zcp-tree { font-size: 12px; }
.zcp-state-group { margin-bottom: 2px; }
.zcp-state-row { display: flex; align-items: center; gap: 4px; padding: 3px 0; }
.zcp-state-name { font-weight: 600; color: #0369a1; flex: 1; }
.zcp-arrow { background: none; border: none; cursor: pointer; color: #94a3b8; font-size: 11px; padding: 0 3px; line-height: 1; }
.zcp-arrow-sm { margin-left: auto; flex-shrink: 0; }
.zcp-all-btn { background: #eff6ff; border: none; cursor: pointer; color: #1d4ed8; font-size: 10px; padding: 1px 5px; border-radius: 3px; flex-shrink: 0; }
.zcp-children { margin-left: 14px; }
.zcp-l2 { margin-left: 14px; }
.zcp-l3 { margin-left: 14px; }
.zcp-node-group { display: flex; flex-direction: column; }
.zcp-item { display: flex; align-items: center; gap: 5px; padding: 3px 4px; border-radius: 4px; cursor: pointer; font-size: 11px; color: #334155; }
.zcp-item:hover { background: #f1f5f9; }
.zcp-item input[type=checkbox] { flex-shrink: 0; accent-color: #2563eb; }
.zcp-item-zone { color: #1e40af; }
.zcp-item-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.zcp-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
.zcp-tag { font-size: 9px; background: #e2e8f0; color: #475569; border-radius: 3px; padding: 0 4px; flex-shrink: 0; white-space: nowrap; }
.zcp-empty { color: #94a3b8; font-size: 12px; padding: 10px 0; }

/* Form column */
.zcp-form-col { width: 260px; flex-shrink: 0; overflow-y: auto; padding: 10px; display: flex; flex-direction: column; gap: 10px; }
.zcp-fg { display: flex; flex-direction: column; gap: 4px; }
.zcp-label { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: #64748b; }
.zcp-input { background: #fff; border: 1px solid #cbd5e1; border-radius: 6px; color: #1e293b; padding: 5px 8px; font-size: 12px; width: 100%; }
.zcp-input:focus { outline: 2px solid #3b82f6; outline-offset: 0; }
.zcp-readonly { font-size: 12px; color: #475569; background: #f1f5f9; border-radius: 4px; padding: 4px 8px; }
.zcp-hint { font-size: 11px; color: #94a3b8; font-style: italic; }
.zcp-warn { font-size: 11px; color: #d97706; }
.zcp-muted { font-size: 12px; color: #64748b; }
.zcp-chips { display: flex; flex-wrap: wrap; gap: 3px; max-height: 100px; overflow-y: auto; }
.zcp-chip { background: #eff6ff; color: #1d4ed8; border-radius: 4px; padding: 2px 6px; font-size: 11px; display: flex; align-items: center; gap: 3px; }
.zcp-chip button { background: none; border: none; cursor: pointer; color: #60a5fa; font-size: 13px; line-height: 1; padding: 0; }
.zcp-badge { background: #dbeafe; color: #1d4ed8; border-radius: 10px; padding: 1px 6px; font-size: 10px; margin-left: 4px; }
.zcp-color-row { display: flex; align-items: center; gap: 8px; }
.zcp-color-pick { width: 36px; height: 28px; border: none; background: none; cursor: pointer; padding: 0; }
.zcp-status { padding: 6px 8px; border-radius: 6px; font-size: 12px; }
.zcp-status.info    { background: #f1f5f9; color: #475569; }
.zcp-status.success { background: #f0fdf4; color: #166534; }
.zcp-status.error   { background: #fef2f2; color: #991b1b; }
.zcp-btn-row { display: flex; gap: 8px; }
.zcp-btn { padding: 6px 12px; border-radius: 6px; font-size: 12px; font-weight: 500; cursor: pointer; border: none; }
.zcp-btn-p { background: #2563eb; color: #fff; }
.zcp-btn-s { background: #f1f5f9; color: #334155; }
.zcp-btn:hover { opacity: 0.85; }
</style>
