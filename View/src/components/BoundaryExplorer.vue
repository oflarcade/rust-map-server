<script setup lang="ts">
import { ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useTileInspector, type HierarchyState, type HierarchyLGA } from '../composables/useTileInspector';
import { TENANTS } from '../config/tenants';

const router = useRouter();

const {
  selectedTenantId,
  currentTenant,
  boundarySearch,
  boundaryHierarchy,
  filteredHierarchy,
  highlightBoundary,
  flyToHierarchyItem,
  highlight,
} = useTileInspector();

const hierarchy = filteredHierarchy;

const expandedStates = ref(new Set<string>());
const activeHighlight = ref<string | null>(null);

function selectState(pcode: string, name: string) {
  if (expandedStates.value.has(pcode)) {
    expandedStates.value.delete(pcode);
    activeHighlight.value = null;
    highlightBoundary(null);
  } else {
    expandedStates.value.add(pcode);
    activeHighlight.value = name;
    highlightBoundary(name);
    // Fly to state using center coordinates from hierarchy
    const state = boundaryHierarchy.value?.states.find((s) => s.pcode === pcode);
    if (state) flyToHierarchyItem(state);
  }
  expandedStates.value = new Set(expandedStates.value);
}

function selectLga(name: string, lga?: HierarchyLGA, state?: HierarchyState) {
  if (activeHighlight.value === name) {
    activeHighlight.value = null;
    highlightBoundary(null);
  } else {
    activeHighlight.value = name;
    highlightBoundary(name);
    if (lga && state) flyToHierarchyItem(state, lga);
  }
}

function isExpanded(pcode: string): boolean {
  return expandedStates.value.has(pcode);
}

function highlightPcode(pcode: string): string {
  return highlight(pcode, boundarySearch.value);
}

watch(boundarySearch, (q) => {
  if (!q || !filteredHierarchy.value) {
    expandedStates.value = new Set();
    return;
  }
  const query = q.toLowerCase();
  const toExpand = new Set<string>();
  for (const state of filteredHierarchy.value.states) {
    const hasMatchingLga = state.lgas.some(
      (lga) =>
        lga.name.toLowerCase().includes(query) ||
        lga.pcode.toLowerCase().includes(query),
    );
    if (
      hasMatchingLga ||
      state.name.toLowerCase().includes(query) ||
      state.pcode.toLowerCase().includes(query)
    ) {
      toExpand.add(state.pcode);
    }
  }
  expandedStates.value = toExpand;
});
</script>

<template>
  <aside class="boundary-explorer">
    <!-- Tenant selector -->
    <div class="tenant-section">
      <div class="tenant-label">Tenant</div>
      <select v-model="selectedTenantId" class="tenant-select">
        <option v-for="t in TENANTS" :key="t.id" :value="t.id">
          {{ t.id }} — {{ t.name }}
        </option>
      </select>
      <div class="tenant-name">{{ currentTenant.name }}</div>
      <button class="nav-btn" @click="router.push('/admin/zones')">
        Manage Zones →
      </button>
    </div>

    <!-- Search -->
    <section class="section">
      <div class="search-wrap">
        <input
          v-model="boundarySearch"
          class="input"
          placeholder="Search by name or pcode..."
        />
        <button
          v-if="boundarySearch"
          class="search-clear"
          @click="boundarySearch = ''"
        >
          ×
        </button>
      </div>
      <div v-if="boundarySearch && hierarchy" class="search-counts">
        {{ hierarchy.states.length }}
        state{{ hierarchy.states.length !== 1 ? 's' : '' }},
        {{ hierarchy.states.reduce((n, s) => n + s.lgas.length, 0) }}
        LGA{{ hierarchy.states.reduce((n, s) => n + s.lgas.length, 0) !== 1 ? 's' : '' }}
      </div>
    </section>

    <!-- Hierarchy Tree -->
    <section v-if="hierarchy" class="section">
      <div class="subhead">Boundary Hierarchy</div>
      <div class="hierarchy-tree">
        <div class="tree-country">
          <span
            class="tree-label"
            v-html="
              highlight(hierarchy.name, boundarySearch) +
              ' (' +
              highlightPcode(hierarchy.pcode) +
              ')'
            "
          ></span>
          <span class="tree-meta">
            {{ hierarchy.state_count ?? hierarchy.states.length }} states
          </span>
        </div>

        <div
          v-for="state in hierarchy.states"
          :key="state.pcode"
          class="tree-state-group"
        >
          <button
            class="tree-state"
            :class="{ active: activeHighlight === state.name }"
            :title="`${state.name} (${state.pcode})`"
            @click="selectState(state.pcode, state.name)"
          >
            <span class="tree-arrow">
              {{ isExpanded(state.pcode) ? '▾' : '▸' }}
            </span>
            <span
              class="tree-label"
              v-html="
                highlight(state.name, boundarySearch) +
                ' (' +
                highlightPcode(state.pcode) +
                ')'
              "
            ></span>
          </button>
          <div v-if="isExpanded(state.pcode)" class="tree-lgas">
            <button
              v-for="lga in state.lgas"
              :key="lga.pcode"
              class="tree-lga"
              :class="{ active: activeHighlight === lga.name }"
              :title="`${lga.name} (${lga.pcode})`"
              @click="selectLga(lga.name, lga, state)"
            >
              <span
                class="tree-label"
                v-html="
                  highlight(lga.name, boundarySearch) +
                  ' (' +
                  highlightPcode(lga.pcode) +
                  ')'
                "
              ></span>
            </button>
          </div>
          <div v-if="isExpanded(state.pcode) && state.zones && state.zones.length > 0" class="tree-zones">
            <div class="tree-zones-label">Zones</div>
            <button
              v-for="zone in state.zones"
              :key="zone.zone_pcode"
              class="tree-zone"
              :title="`${zone.zone_name} (${zone.zone_pcode})`"
              @click="selectLga(zone.zone_name)"
              :class="{ active: activeHighlight === zone.zone_name }"
            >
              <span class="zone-dot" :style="{ background: zone.color ?? '#a78bfa' }"></span>
              <span class="tree-label" v-html="highlight(zone.zone_name, boundarySearch) + ' (' + zone.zone_pcode + ')'"></span>
            </button>
          </div>
        </div>
      </div>
    </section>

  </aside>
</template>

<style scoped>
.boundary-explorer {
  background: #020617;
  color: #e5e7eb;
  overflow-y: auto;
  padding: 14px;
  border-right: 1px solid #1f2937;
  height: 100%;
}

.section {
  margin-top: 12px;
  padding-top: 10px;
  border-top: 1px solid #1f2937;
}

.section:first-child {
  margin-top: 0;
  padding-top: 0;
  border-top: none;
}

.subhead {
  font-size: 13px;
  margin-bottom: 6px;
  color: #cbd5e1;
  font-weight: 600;
}

.input {
  width: 100%;
  background: #020617;
  color: #e5e7eb;
  border: 1px solid #334155;
  border-radius: 6px;
  padding: 8px;
  font-size: 13px;
}

.search-wrap {
  position: relative;
}

.search-wrap .input {
  padding-right: 28px;
}

.search-clear {
  position: absolute;
  right: 8px;
  top: 50%;
  transform: translateY(-50%);
  background: none;
  border: none;
  color: #6b7280;
  cursor: pointer;
  font-size: 16px;
  line-height: 1;
  padding: 0;
}

.search-clear:hover {
  color: #e5e7eb;
}

.search-counts {
  font-size: 11px;
  color: #6b7280;
  margin-top: 6px;
}

.hierarchy-tree {
  overflow-y: auto;
  border: 1px solid #1f2937;
  border-radius: 6px;
  padding: 8px;
  font-size: 12px;
}

.tree-country {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 4px 0;
  border-bottom: 1px solid #1f2937;
  margin-bottom: 4px;
}

.tree-country .tree-label {
  font-weight: 600;
  color: #67e8f9;
}

.tree-meta {
  font-size: 10px;
  color: #6b7280;
}

.tree-state-group {
  margin-left: 4px;
}

.tree-state {
  display: flex;
  align-items: center;
  gap: 4px;
  width: 100%;
  padding: 3px 0;
  background: none;
  border: none;
  color: #e5e7eb;
  cursor: pointer;
  font-size: 12px;
  text-align: left;
}

.tree-state:hover {
  color: #67e8f9;
}

.tree-state.active {
  color: #3b82f6;
  font-weight: 600;
}

.tree-arrow {
  width: 12px;
  flex-shrink: 0;
  color: #6b7280;
  font-size: 10px;
}

.tree-lgas {
  margin-left: 20px;
}

.tree-lga {
  display: block;
  width: 100%;
  padding: 2px 0;
  background: none;
  border: none;
  color: #9ca3af;
  cursor: pointer;
  font-size: 11px;
  text-align: left;
}

.tree-lga:hover {
  color: #67e8f9;
}

.tree-lga.active {
  color: #3b82f6;
  font-weight: 600;
}

.tree-label :deep(mark) {
  background: #1e4d78;
  color: #bae6fd;
  border-radius: 2px;
  padding: 0 1px;
}

.tree-zones { margin-top: 4px; margin-left: 12px; }
.tree-zones-label { font-size: 10px; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 2px; }
.tree-zone { display: flex; align-items: center; gap: 6px; width: 100%; text-align: left; background: none; border: none; color: #c4b5fd; cursor: pointer; padding: 3px 6px; border-radius: 4px; font-size: 11px; }
.tree-zone:hover { background: #1e1b4b; }
.tree-zone.active { background: #312e81; }
.zone-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }

.tenant-section {
  padding-bottom: 12px;
  border-bottom: 1px solid #1f2937;
  margin-bottom: 12px;
}

.tenant-label {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: #64748b;
  margin-bottom: 6px;
}

.tenant-select {
  width: 100%;
  background: #0f172a;
  color: #e5e7eb;
  border: 1px solid #334155;
  border-radius: 6px;
  padding: 6px 8px;
  font-size: 13px;
  cursor: pointer;
}

.tenant-name {
  margin-top: 5px;
  font-size: 11px;
  color: #67e8f9;
  font-weight: 600;
}

.nav-btn {
  margin-top: 8px;
  width: 100%;
  background: #1e3a5f;
  color: #67e8f9;
  border: 1px solid #1e4d78;
  border-radius: 6px;
  padding: 6px 10px;
  font-size: 12px;
  cursor: pointer;
  text-align: center;
}

.nav-btn:hover {
  background: #1e4d78;
}

@media (max-width: 800px) {
  .boundary-explorer {
    border-right: 0;
    border-bottom: 1px solid #1f2937;
    max-height: 40vh;
  }
}
</style>
