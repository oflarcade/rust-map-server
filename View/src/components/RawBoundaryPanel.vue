<script setup lang="ts">
import { ref, computed, reactive } from 'vue';
import { useGeoHierarchyEditor } from '../composables/useGeoHierarchyEditor';
import { useTileInspector } from '../composables/useTileInspector';

const {
  rawHierarchy,
  rawLoading,
  rawError,
  selectionMode,
  selectedRawPcodes,
  assignedPcodes,
  targetNodeId,
  targetStatePcode,
  geoNodes,
  togglePcode,
  exitSelectionMode,
  assignSelectedToNode,
  focusedStatePcode,
  activateState,
  addStateToHierarchy,
  showCountryRoot,
  adm2Label,
  adm2Short,
} = useGeoHierarchyEditor();

const { currentTenant } = useTileInspector();

// ---------------------------------------------------------------------------
// adm3+ sector support — mirror of HierarchyBuilderPanel.vue
// ---------------------------------------------------------------------------

/** Map: adm2 pcode → adm3+ children from raw hierarchy */
const parentChildMap = computed<Map<string, any[]>>(() => {
  const m = new Map<string, any[]>();
  for (const s of rawHierarchy.value?.states ?? []) {
    for (const adm2 of (s as any).adm2s ?? []) {
      if (adm2.children?.length) m.set(adm2.pcode, adm2.children);
    }
  }
  return m;
});

/** All adm3+ child pcodes — distinguishes adm2 from adm3+ in constituent_pcodes */
const childPcodeSet = computed<Set<string>>(() => {
  const s = new Set<string>();
  for (const children of parentChildMap.value.values()) {
    for (const c of children) s.add(c.pcode);
  }
  return s;
});

/** Resolve the GeoNode object currently being targeted for assignment */
const targetNodeObj = computed(() =>
  targetNodeId.value ? geoNodes.value.find(n => n.id === targetNodeId.value) ?? null : null
);

/**
 * Set of LGA pcodes that already belong to the target node (highlighted amber
 * in the raw panel so the user can see what is currently assigned there).
 */
const targetHighlightLgaPcodes = computed<Set<string>>(() => {
  if (selectionMode.value !== 'selecting') return new Set();
  const node = targetNodeObj.value;
  if (!node) return new Set();
  const pcodes = node.constituent_pcodes ?? [];
  if (pcodes.length === 0) return new Set();
  const result = new Set<string>();
  const hasChildren = pcodes.some(p => childPcodeSet.value.has(p));
  if (hasChildren) {
    for (const [adm2Pcode, children] of parentChildMap.value.entries()) {
      if (children.some((c: any) => pcodes.includes(c.pcode))) result.add(adm2Pcode);
    }
  } else {
    for (const p of pcodes) result.add(p);
  }
  return result;
});

const COUNTRY_NAMES: Record<string, string> = {
  NG: 'Nigeria', KE: 'Kenya', UG: 'Uganda', RW: 'Rwanda',
  LR: 'Liberia', CF: 'Central African Republic', IN: 'India',
};
const countryName = computed(() =>
  COUNTRY_NAMES[currentTenant.value.countryCode?.toUpperCase() ?? ''] ?? currentTenant.value.name,
);
const panelTitle = computed(() =>
  showCountryRoot.value ? `${countryName.value} Geo Tree` : `${currentTenant.value.name} Geo Tree`,
);

const expandedStates  = reactive(new Set<string>());
const expandedLgas    = reactive(new Set<string>());
const buildingStates  = reactive(new Set<string>()); // states currently auto-creating nodes
const searchQ = ref('');

// Flat pcode → info map covering adm2 AND adm3+ children (for assign label + select-all)
const rawPcodeInfo = computed(() => {
  const m = new Map<string, { name: string; level_label: string }>();
  for (const state of rawHierarchy.value?.states ?? []) {
    for (const adm2 of (state as any).adm2s ?? []) {
      m.set(adm2.pcode, { name: adm2.name, level_label: adm2.level_label ?? adm2Label.value });
      for (const child of (adm2.children ?? []) as any[]) {
        m.set(child.pcode, { name: child.name, level_label: child.level_label ?? '' });
      }
    }
  }
  return m;
});

// Smart label for assign button: "District" / "Sector" / "item" (when mixed)
const assignLabel = computed(() => {
  const labels = new Set<string>();
  for (const pcode of selectedRawPcodes.value) {
    const lbl = rawPcodeInfo.value.get(pcode)?.level_label;
    if (lbl) labels.add(lbl);
  }
  if (labels.size === 1) return [...labels][0];
  return 'item';
});

function selectAllChildren(children: any[]) {
  const s = new Set(selectedRawPcodes.value);
  const eligible = (children as any[]).filter(c => !isAssigned(c.pcode) || s.has(c.pcode));
  const allSelected = eligible.length > 0 && eligible.every(c => s.has(c.pcode));
  if (allSelected) {
    eligible.forEach(c => s.delete(c.pcode));
  } else {
    eligible.filter(c => !isAssigned(c.pcode)).forEach(c => s.add(c.pcode));
  }
  selectedRawPcodes.value = s;
}

function toggleState(pcode: string, ev?: Event) {
  ev?.stopPropagation();
  if (expandedStates.has(pcode)) expandedStates.delete(pcode);
  else expandedStates.add(pcode);
}

async function onStateRowClick(pcode: string) {
  expandedStates.add(pcode);
  if (buildingStates.has(pcode)) return; // already in progress
  buildingStates.add(pcode);
  try {
    await addStateToHierarchy(pcode); // API call + activates in custom tree
  } finally {
    buildingStates.delete(pcode);
  }
}

const targetNodeName = computed(() => {
  if (targetStatePcode.value) {
    const state = rawHierarchy.value?.states?.find((s: any) => s.pcode === targetStatePcode.value);
    return state?.name ?? targetStatePcode.value;
  }
  if (!targetNodeId.value) return '';
  return geoNodes.value.find(n => n.id === targetNodeId.value)?.name ?? '';
});

function isAssigned(pcode: string) {
  return assignedPcodes.value.has(pcode);
}

function isSelected(pcode: string) {
  return selectedRawPcodes.value.has(pcode);
}

function filteredLgas(lgas: any[]) {
  if (!searchQ.value) return lgas;
  const q = searchQ.value.toLowerCase();
  return lgas.filter(l => l.name.toLowerCase().includes(q) || l.pcode.toLowerCase().includes(q));
}

async function doAssign() {
  await assignSelectedToNode();
}
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Header -->
    <div class="px-2 py-1.5 bg-slate-50/80 border-b border-slate-200/90 flex-shrink-0">
      <div class="text-[10px] font-semibold text-slate-500 uppercase tracking-wider mb-1 truncate" :title="panelTitle">
        {{ panelTitle }}
      </div>
      <input
        v-model="searchQ"
        :placeholder="`Search ${adm2Label}s…`"
        class="w-full border border-slate-200 rounded px-2 py-1 text-xs"
      />
    </div>

    <!-- Selection mode banner -->
    <div
      v-if="selectionMode === 'selecting'"
      class="bg-indigo-50 border-b border-indigo-200 px-3 py-2 flex-shrink-0"
    >
      <div class="text-xs text-indigo-700 font-medium">
        Selecting for: <span class="font-bold">{{ targetNodeName }}</span>
      </div>
      <div class="text-xs text-indigo-500 mt-0.5">
        {{ selectedRawPcodes.size }} selected
      </div>
    </div>

    <!-- Content -->
    <div class="flex-1 overflow-y-auto text-xs">
      <div v-if="rawLoading" class="p-3 text-slate-400">Loading…</div>
      <div v-else-if="rawError" class="p-3 text-red-600">Error loading boundaries</div>
      <div v-else-if="!rawHierarchy?.states?.length" class="p-3 text-slate-400 italic">
        No boundary data for this tenant.
      </div>
      <template v-else>
        <!-- Country root row (mirrors custom tree right panel) -->
        <div
          v-if="showCountryRoot"
          class="flex items-center gap-2 px-3 py-1.5 bg-slate-100/80 border-b border-slate-200/60 sticky top-0 z-10"
        >
          <i class="pi pi-globe text-[10px] text-slate-500 flex-shrink-0" />
          <span class="font-bold text-slate-700 text-[11px]">{{ countryName }}</span>
          <span class="text-[9px] font-mono text-slate-400">adm0</span>
        </div>

        <div v-for="state in rawHierarchy.states" :key="state.pcode">
          <!-- State row: chevron toggles expand; row name activates + focuses custom tree -->
          <div
            class="w-full flex items-stretch font-semibold text-slate-700 transition-colors"
            :class="[
              focusedStatePcode === state.pcode ? 'bg-indigo-50/90' : 'hover:bg-slate-50',
              showCountryRoot ? 'pl-3' : '',
              selectionMode === 'selecting' && targetStatePcode === state.pcode
                ? 'bg-amber-50/80 border-l-2 border-amber-400'
                : '',
            ]"
          >
            <button
              type="button"
              class="px-2 py-1.5 text-slate-400 hover:text-slate-600 shrink-0"
              :aria-expanded="expandedStates.has(state.pcode)"
              title="Expand or collapse LGAs"
              @click="toggleState(state.pcode, $event)"
            >
              <i
                :class="expandedStates.has(state.pcode) ? 'pi pi-chevron-down' : 'pi pi-chevron-right'"
                class="text-[9px]"
              />
            </button>
            <button
              type="button"
              class="flex-1 flex items-center gap-1.5 px-1 pr-3 py-1.5 text-left min-w-0"
              :title="buildingStates.has(state.pcode) ? 'Building hierarchy…' : 'Add to geo hierarchy'"
              :disabled="buildingStates.has(state.pcode)"
              @click="onStateRowClick(state.pcode)"
            >
              <i
                v-if="buildingStates.has(state.pcode)"
                class="pi pi-spin pi-spinner text-[9px] text-indigo-400 shrink-0"
              />
              <span class="truncate">{{ state.name }}</span>
              <span class="text-[9px] text-slate-400 italic shrink-0">{{ adm1Label }}</span>
              <span class="ml-auto text-[10px] text-slate-400 font-normal shrink-0">{{ state.pcode }}</span>
            </button>
          </div>

          <!-- LGAs (adm2) — and optional adm3+ children (e.g. Sectors for Rwanda) -->
          <div v-if="expandedStates.has(state.pcode)">
            <template v-for="lga in filteredLgas(state.adm2s ?? [])" :key="lga.pcode">
              <!-- LGA row -->
              <div
                class="flex items-stretch gap-2 pr-3 hover:bg-slate-50"
                :class="{
                  'bg-indigo-50/80 border-l-2 border-indigo-400': isSelected(lga.pcode),
                  'bg-amber-50/60 border-l-2 border-amber-300': !isSelected(lga.pcode) && targetHighlightLgaPcodes.has(lga.pcode),
                }"
              >
                <!-- expand toggle (only when lga has children) -->
                <button
                  v-if="lga.children?.length"
                  type="button"
                  class="pl-7 pr-1 py-1 text-slate-400 hover:text-slate-600 shrink-0"
                  @click.stop="expandedLgas.has(lga.pcode) ? expandedLgas.delete(lga.pcode) : expandedLgas.add(lga.pcode)"
                >
                  <i :class="expandedLgas.has(lga.pcode) ? 'pi pi-chevron-down' : 'pi pi-chevron-right'" class="text-[9px]" />
                </button>
                <div v-else class="pl-7 pr-3 shrink-0" />

                <div class="flex flex-1 items-center gap-2 py-1 min-w-0">
                  <input
                    v-if="selectionMode === 'selecting'"
                    type="checkbox"
                    :checked="isSelected(lga.pcode)"
                    :disabled="isAssigned(lga.pcode) && !isSelected(lga.pcode)"
                    class="w-3 h-3 accent-indigo-600 flex-shrink-0"
                    @change="togglePcode(lga.pcode)"
                  />
                  <span class="flex-1 truncate" :class="isSelected(lga.pcode) ? 'text-indigo-700 font-medium' : 'text-slate-700'">
                    {{ lga.name }}
                  </span>
                  <span v-if="lga.level_label" class="text-[9px] text-slate-400 italic flex-shrink-0">{{ lga.level_label }}</span>
                  <span class="text-[10px] text-slate-400 font-mono flex-shrink-0">{{ lga.pcode }}</span>
                  <span v-if="isAssigned(lga.pcode)" class="text-[9px] text-slate-400 italic flex-shrink-0">assigned</span>
                </div>
              </div>

              <!-- adm3+ children (e.g. Sectors for Rwanda) -->
              <div v-if="lga.children?.length && expandedLgas.has(lga.pcode)">
                <!-- Select-all row -->
                <div
                  v-if="selectionMode === 'selecting'"
                  class="flex items-center gap-2 pl-14 pr-3 py-0.5 bg-slate-50/80 border-b border-slate-100"
                >
                  <button
                    type="button"
                    class="text-[10px] text-indigo-600 hover:text-indigo-800 font-medium"
                    @click="selectAllChildren(lga.children)"
                  >
                    {{ lga.children.every((c: any) => isSelected(c.pcode) || isAssigned(c.pcode)) || lga.children.filter((c: any) => !isAssigned(c.pcode)).every((c: any) => isSelected(c.pcode)) ? 'Deselect all' : 'Select all' }}
                  </button>
                  <span class="text-[9px] text-slate-400">
                    {{ lga.children.filter((c: any) => isSelected(c.pcode)).length }}/{{ lga.children.length }}
                  </span>
                </div>
                <!-- Individual sector rows -->
                <div
                  v-for="child in lga.children"
                  :key="child.pcode"
                  class="flex items-center gap-2 pl-14 pr-3 py-0.5 hover:bg-slate-50"
                  :class="{
                    'bg-indigo-50': isSelected(child.pcode),
                  }"
                >
                  <input
                    v-if="selectionMode === 'selecting'"
                    type="checkbox"
                    :checked="isSelected(child.pcode)"
                    :disabled="isAssigned(child.pcode) && !isSelected(child.pcode)"
                    class="w-3 h-3 accent-indigo-600 flex-shrink-0"
                    @change="togglePcode(child.pcode)"
                  />
                  <span v-else class="w-1 h-1 rounded-full bg-slate-300 flex-shrink-0" />
                  <span
                    class="flex-1 truncate text-[11px]"
                    :class="isSelected(child.pcode) ? 'text-indigo-700 font-medium' : 'text-slate-500'"
                  >{{ child.name }}</span>
                  <span class="text-[10px] font-mono text-slate-400 flex-shrink-0">{{ child.pcode }}</span>
                  <span v-if="isAssigned(child.pcode)" class="text-[9px] text-slate-400 italic flex-shrink-0">assigned</span>
                </div>
              </div>
            </template>

            <div
              v-if="filteredLgas(state.adm2s ?? []).length === 0"
              class="pl-7 pr-3 py-1 text-slate-400 italic"
            >
              No results
            </div>
          </div>
        </div>
      </template>
    </div>

    <!-- Sticky assignment footer -->
    <div
      v-if="selectionMode === 'selecting'"
      class="flex-shrink-0 border-t border-slate-200 bg-white px-3 py-2.5 flex items-center gap-2"
    >
      <button
        class="flex-1 py-2 px-3 rounded-lg text-[13px] font-semibold transition-all duration-150
               bg-indigo-600 text-white hover:bg-indigo-700 active:scale-[0.98]
               disabled:opacity-40 disabled:cursor-not-allowed"
        :disabled="selectedRawPcodes.size === 0"
        @click="doAssign"
      >
        Assign {{ selectedRawPcodes.size }} {{ assignLabel }}{{ selectedRawPcodes.size !== 1 ? 's' : '' }}
      </button>
      <button
        class="py-2 px-3 rounded-lg text-[13px] font-medium transition-all duration-150
               text-slate-600 border border-slate-200 hover:border-slate-300 hover:bg-slate-50 active:scale-[0.98]"
        @click="exitSelectionMode"
      >
        Cancel
      </button>
    </div>
  </div>
</template>
