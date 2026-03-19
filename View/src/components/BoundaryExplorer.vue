<script setup lang="ts">
import { ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useTileInspector, type HierarchyState, type HierarchyLGA, type HierarchyZone, type HierarchyAdmNode, type HierarchyChild } from '../composables/useTileInspector';
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
const expandedZones = ref(new Set<string>());
const activeHighlight = ref<string | null>(null);

function selectState(pcode: string, name: string) {
  if (expandedStates.value.has(pcode)) {
    expandedStates.value.delete(pcode);
    activeHighlight.value = null;
    highlightBoundary(null);
  } else {
    expandedStates.value.add(pcode);
    activeHighlight.value = pcode;
    highlightBoundary({ pcode, level: 'state', name });
    const state = boundaryHierarchy.value?.states.find((s) => s.pcode === pcode);
    if (state) flyToHierarchyItem(state);
  }
  expandedStates.value = new Set(expandedStates.value);
}

function selectLga(lga: HierarchyLGA, state: HierarchyState) {
  if (activeHighlight.value === lga.pcode) {
    activeHighlight.value = null;
    highlightBoundary(null);
  } else {
    activeHighlight.value = lga.pcode;
    highlightBoundary({ pcode: lga.pcode, level: 'lga', name: lga.name });
    flyToHierarchyItem(state, lga);
  }
}

function selectZone(zone: HierarchyZone) {
  if (activeHighlight.value === zone.zone_pcode) {
    activeHighlight.value = null;
    highlightBoundary(null);
  } else {
    activeHighlight.value = zone.zone_pcode;
    highlightBoundary({ pcode: zone.zone_pcode, level: 'zone' });
  }
}

function toggleZone(pcode: string) {
  if (expandedZones.value.has(pcode)) {
    expandedZones.value.delete(pcode);
  } else {
    expandedZones.value.add(pcode);
  }
  expandedZones.value = new Set(expandedZones.value);
}

function isZoneExpanded(pcode: string): boolean {
  return expandedZones.value.has(pcode);
}

function selectLgaLeaf(pcode: string, name: string) {
  activeHighlight.value = pcode;
  highlightBoundary({ pcode, level: 'lga', name });
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
        Tenant Administrative Manager →
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
            :class="{ active: activeHighlight === state.pcode }"
            :title="`${state.name} (${state.pcode})`"
            @click="selectState(state.pcode, state.name)"
          >
            <span class="tree-arrow">
              {{ isExpanded(state.pcode) ? '▾' : '▸' }}
            </span>
            <span class="tree-label">
              <span v-if="state.level_label" class="level-tag">{{ state.level_label }}</span>
              <span v-html="highlight(state.name, boundarySearch) + ' (' + highlightPcode(state.pcode) + ')'"></span>
            </span>
          </button>
          <!-- Flat lgas list: only shown when children tree doesn't cover this level -->
          <!-- Hidden for countries like Rwanda where state.children has adm feature nodes -->
          <div v-if="isExpanded(state.pcode) && state.lgas.length > 0 && !(state.children?.length && !(state.children[0] as HierarchyZone).zone_pcode)" class="tree-lgas">
            <button
              v-for="lga in state.lgas"
              :key="lga.pcode"
              class="tree-lga"
              :class="{ active: activeHighlight === lga.pcode }"
              :title="`${lga.name} (${lga.pcode})`"
              @click="selectLga(lga, state)"
            >
              <span class="tree-label">
                <span v-if="lga.level_label" class="level-tag">{{ lga.level_label }}</span>
                <span v-html="highlight(lga.name, boundarySearch) + ' (' + highlightPcode(lga.pcode) + ')'"></span>
              </span>
            </button>
          </div>
          <div v-if="isExpanded(state.pcode) && state.children && state.children.length > 0" class="tree-zones">
            <div v-for="z1 in state.children" :key="(z1 as HierarchyZone).zone_pcode ?? (z1 as HierarchyAdmNode).pcode" class="tree-zone-group">
              <!-- Adm feature (e.g. Rwanda District) -->
              <template v-if="!(z1 as HierarchyZone).is_zone && !(z1 as HierarchyZone).zone_pcode">
                <button
                  class="tree-zone tree-zone-l1"
                  :class="{ active: activeHighlight === (z1 as HierarchyAdmNode).pcode }"
                  @click="(z1 as HierarchyAdmNode).children?.length ? toggleZone((z1 as HierarchyAdmNode).pcode) : null; selectLgaLeaf((z1 as HierarchyAdmNode).pcode, (z1 as HierarchyAdmNode).name)"
                >
                  <span class="zone-arrow">{{ (z1 as HierarchyAdmNode).children?.length ? (isZoneExpanded((z1 as HierarchyAdmNode).pcode) ? '▾' : '▸') : '·' }}</span>
                  <span class="tree-label">
                    <span v-if="(z1 as HierarchyAdmNode).level_label" class="level-tag">{{ (z1 as HierarchyAdmNode).level_label }}</span>
                    <span v-html="highlight((z1 as HierarchyAdmNode).name, boundarySearch)"></span>
                  </span>
                </button>
                <div v-if="isZoneExpanded((z1 as HierarchyAdmNode).pcode) && (z1 as HierarchyAdmNode).children?.length" class="tree-zone-children">
                  <div v-for="z2 in (z1 as HierarchyAdmNode).children" :key="z2.pcode" class="tree-zone-group">
                    <button
                      class="tree-zone tree-zone-l2"
                      :class="{ active: activeHighlight === z2.pcode }"
                      @click="z2.children?.length ? toggleZone(z2.pcode) : null; selectLgaLeaf(z2.pcode, z2.name)"
                    >
                      <span class="zone-arrow">{{ z2.children?.length ? (isZoneExpanded(z2.pcode) ? '▾' : '▸') : '·' }}</span>
                      <span class="tree-label">
                        <span v-if="z2.level_label" class="level-tag">{{ z2.level_label }}</span>
                        <span v-html="highlight(z2.name, boundarySearch)"></span>
                      </span>
                    </button>
                    <div v-if="isZoneExpanded(z2.pcode) && z2.children?.length" class="tree-zone-children">
                      <button
                        v-for="z3 in z2.children"
                        :key="z3.pcode"
                        class="tree-zone tree-zone-l3"
                        :class="{ active: activeHighlight === z3.pcode }"
                        @click="selectLgaLeaf(z3.pcode, z3.name)"
                      >
                        <span class="zone-arrow">·</span>
                        <span class="tree-label">
                          <span v-if="z3.level_label" class="level-tag">{{ z3.level_label }}</span>
                          <span v-html="highlight(z3.name, boundarySearch)"></span>
                        </span>
                      </button>
                    </div>
                  </div>
                </div>
              </template>
              <!-- Zone node (e.g. Jigawa Senatorial/Emirate/FC) -->
              <template v-else>
                <button
                  class="tree-zone tree-zone-l1"
                  :class="{ active: activeHighlight === (z1 as HierarchyZone).zone_pcode }"
                  :title="`${(z1 as HierarchyZone).zone_name} (${(z1 as HierarchyZone).zone_pcode})`"
                  @click="toggleZone((z1 as HierarchyZone).zone_pcode); selectZone(z1 as HierarchyZone)"
                >
                  <span class="zone-arrow">{{ isZoneExpanded((z1 as HierarchyZone).zone_pcode) ? '▾' : '▸' }}</span>
                  <span class="zone-dot" :style="{ background: (z1 as HierarchyZone).color ?? '#10b981' }"></span>
                  <span class="tree-label">
                    <span v-if="(z1 as HierarchyZone).zone_type_label" class="level-tag">{{ (z1 as HierarchyZone).zone_type_label }}</span>
                    <span v-html="highlight((z1 as HierarchyZone).zone_name, boundarySearch)"></span>
                  </span>
                </button>
                <!-- Level 2 zones -->
                <div v-if="isZoneExpanded((z1 as HierarchyZone).zone_pcode) && (z1 as HierarchyZone).children?.length" class="tree-zone-children">
                  <div v-for="z2 in (z1 as HierarchyZone).children as HierarchyZone[]" :key="z2.zone_pcode" class="tree-zone-group">
                    <button
                      class="tree-zone tree-zone-l2"
                      :class="{ active: activeHighlight === z2.zone_pcode }"
                      :title="`${z2.zone_name} (${z2.zone_pcode})`"
                      @click="toggleZone(z2.zone_pcode); selectZone(z2)"
                    >
                      <span class="zone-arrow">{{ isZoneExpanded(z2.zone_pcode) ? '▾' : '▸' }}</span>
                      <span class="zone-dot" :style="{ background: z2.color ?? '#f59e0b' }"></span>
                      <span class="tree-label">
                        <span v-if="z2.zone_type_label" class="level-tag">{{ z2.zone_type_label }}</span>
                        <span v-html="highlight(z2.zone_name, boundarySearch)"></span>
                      </span>
                    </button>
                    <!-- Level 3 zones -->
                    <div v-if="isZoneExpanded(z2.zone_pcode) && z2.children?.length" class="tree-zone-children">
                      <div v-for="z3 in z2.children as HierarchyZone[]" :key="z3.zone_pcode" class="tree-zone-group">
                        <button
                          class="tree-zone tree-zone-l3"
                          :class="{ active: activeHighlight === z3.zone_pcode }"
                          :title="`${z3.zone_name} (${z3.zone_pcode})`"
                          @click="toggleZone(z3.zone_pcode); selectZone(z3)"
                        >
                          <span class="zone-arrow">{{ z3.children?.length ? (isZoneExpanded(z3.zone_pcode) ? '▾' : '▸') : '·' }}</span>
                          <span class="zone-dot" :style="{ background: z3.color ?? '#3b82f6' }"></span>
                          <span class="tree-label">
                            <span v-if="z3.zone_type_label" class="level-tag">{{ z3.zone_type_label }}</span>
                            <span v-html="highlight(z3.zone_name, boundarySearch)"></span>
                          </span>
                        </button>
                        <!-- Level 4: LGAs under FC — expandable if wards exist -->
                        <div v-if="isZoneExpanded(z3.zone_pcode) && z3.children?.length" class="tree-zone-children">
                          <div v-for="lga in z3.children as HierarchyAdmNode[]" :key="lga.pcode" class="tree-zone-group">
                            <button
                              class="tree-zone tree-zone-l4"
                              :class="{ active: activeHighlight === lga.pcode }"
                              :title="`${lga.name} (${lga.pcode})`"
                              @click="lga.children?.length ? toggleZone(lga.pcode) : null; selectLgaLeaf(lga.pcode, lga.name)"
                            >
                              <span class="zone-arrow">{{ lga.children?.length ? (isZoneExpanded(lga.pcode) ? '▾' : '▸') : '·' }}</span>
                              <span class="tree-label">
                                <span class="level-tag">{{ lga.level_label || 'LGA' }}</span>
                                <span v-html="highlight(lga.name, boundarySearch)"></span>
                              </span>
                            </button>
                            <!-- Level 5: Wards -->
                            <div v-if="isZoneExpanded(lga.pcode) && lga.children?.length" class="tree-zone-children">
                              <button
                                v-for="ward in lga.children"
                                :key="ward.pcode"
                                class="tree-zone tree-zone-l5"
                                :class="{ active: activeHighlight === ward.pcode }"
                                @click="selectLgaLeaf(ward.pcode, ward.name)"
                              >
                                <span class="zone-arrow">·</span>
                                <span class="tree-label">
                                  <span class="level-tag">{{ ward.level_label || 'Ward' }}</span>
                                  <span v-html="highlight(ward.name, boundarySearch)"></span>
                                </span>
                              </button>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </template>
            </div>
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
.tree-zone-group { display: flex; flex-direction: column; }
.tree-zone-children { margin-left: 14px; }
.tree-zone { display: flex; align-items: center; gap: 4px; width: 100%; text-align: left; background: none; border: none; color: #c4b5fd; cursor: pointer; padding: 3px 4px; border-radius: 4px; font-size: 11px; }
.tree-zone:hover { background: #1e1b4b; }
.tree-zone.active { background: #312e81; }
.tree-zone-l1 { color: #d1fae5; font-weight: 500; }
.tree-zone-l2 { color: #fde68a; }
.tree-zone-l3 { color: #bfdbfe; }
.tree-zone-l4 { color: #9ca3af; font-size: 10px; }
.tree-zone-l5 { color: #6b7280; font-size: 10px; }
.level-tag { font-size: 9px; text-transform: uppercase; letter-spacing: 0.04em; color: #4b5563; background: #1f2937; border-radius: 3px; padding: 0 4px; margin-right: 4px; flex-shrink: 0; white-space: nowrap; }
.zone-dot { width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0; }
.zone-arrow { width: 10px; flex-shrink: 0; color: #6b7280; font-size: 9px; text-align: center; }

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
