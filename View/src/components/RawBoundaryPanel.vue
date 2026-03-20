<script setup lang="ts">
import { ref, computed } from 'vue';
import Button from 'primevue/button';
import { useGeoHierarchyEditor } from '../composables/useGeoHierarchyEditor';

const {
  rawHierarchy,
  rawLoading,
  rawError,
  selectionMode,
  selectedRawPcodes,
  assignedPcodes,
  targetNodeId,
  geoNodes,
  togglePcode,
  exitSelectionMode,
  assignSelectedToNode,
} = useGeoHierarchyEditor();

const expandedStates = ref<Set<string>>(new Set());
const searchQ = ref('');

function toggleState(pcode: string) {
  const s = new Set(expandedStates.value);
  if (s.has(pcode)) s.delete(pcode);
  else s.add(pcode);
  expandedStates.value = s;
}

const targetNodeName = computed(() => {
  if (!targetNodeId.value) return '';
  const node = geoNodes.value.find(n => n.id === targetNodeId.value);
  return node?.name ?? '';
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
      <div class="text-[10px] font-semibold text-slate-500 uppercase tracking-wider mb-1">Raw</div>
      <input
        v-model="searchQ"
        placeholder="Search LGAs…"
        class="w-full border border-slate-200 rounded px-2 py-1 text-xs"
      />
    </div>

    <!-- Selection mode banner -->
    <div
      v-if="selectionMode === 'selecting'"
      class="bg-indigo-50 border-b border-indigo-200 px-3 py-2 flex-shrink-0"
    >
      <div class="text-xs text-indigo-700 font-medium">
        Selecting LGAs for: <span class="font-bold">{{ targetNodeName }}</span>
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
        <div v-for="state in rawHierarchy.states" :key="state.pcode">
          <!-- State row -->
          <button
            class="w-full flex items-center gap-1.5 px-3 py-1.5 hover:bg-slate-50 font-semibold text-slate-700"
            @click="toggleState(state.pcode)"
          >
            <i
              :class="expandedStates.has(state.pcode) ? 'pi pi-chevron-down' : 'pi pi-chevron-right'"
              class="text-[9px] text-slate-400"
            />
            {{ state.name }}
            <span class="ml-auto text-[10px] text-slate-400 font-normal">{{ state.pcode }}</span>
          </button>

          <!-- LGAs -->
          <div v-if="expandedStates.has(state.pcode)">
            <div
              v-for="lga in filteredLgas(state.lgas ?? [])"
              :key="lga.pcode"
              class="flex items-center gap-2 pl-7 pr-3 py-1 hover:bg-slate-50"
              :class="{
                'opacity-40': isAssigned(lga.pcode) && !isSelected(lga.pcode),
                'bg-indigo-50': isSelected(lga.pcode),
              }"
            >
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
              <span class="text-[10px] text-slate-400 font-mono flex-shrink-0">{{ lga.pcode }}</span>
              <span v-if="isAssigned(lga.pcode)" class="text-[9px] text-slate-400 italic flex-shrink-0">assigned</span>
            </div>
            <div
              v-if="filteredLgas(state.lgas ?? []).length === 0"
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
      class="flex-shrink-0 border-t border-indigo-200 bg-indigo-50 px-3 py-2 flex gap-2"
    >
      <Button
        :label="`Assign ${selectedRawPcodes.size} LGA${selectedRawPcodes.size !== 1 ? 's' : ''}`"
        size="small"
        :disabled="selectedRawPcodes.size === 0"
        class="flex-1"
        @click="doAssign"
      />
      <Button
        label="Cancel"
        size="small"
        severity="secondary"
        outlined
        @click="exitSelectionMode"
      />
    </div>
  </div>
</template>
