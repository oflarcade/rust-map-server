<script setup lang="ts">
import { computed } from 'vue';
import { useTileInspector, type HierarchyState, type HierarchyLGA, type HierarchyChild, type HierarchyZone } from '../composables/useTileInspector';
import { ref } from 'vue';

const { filteredHierarchy, boundarySearch, flyToHierarchyItem, highlightBoundary, highlight, hierarchyPanelOpen } = useTileInspector();

const expandedStates = ref<Set<string>>(new Set());

function isZone(child: HierarchyChild): child is HierarchyZone {
  return (child as any).is_zone === true || (child as any).zone_pcode !== undefined;
}

function toggleState(pcode: string) {
  const next = new Set(expandedStates.value);
  if (next.has(pcode)) next.delete(pcode); else next.add(pcode);
  expandedStates.value = next;
}

function clickState(state: HierarchyState) {
  toggleState(state.pcode);
  flyToHierarchyItem(state);
  highlightBoundary({ pcode: state.pcode, level: 'state', name: state.name });
}

function clickLGA(state: HierarchyState, lga: HierarchyLGA) {
  flyToHierarchyItem(state, lga);
  highlightBoundary({ pcode: lga.pcode, level: 'lga', name: lga.name });
}

function clickZone(zone: HierarchyZone) {
  highlightBoundary({ pcode: zone.zone_pcode, level: 'zone', name: zone.zone_name });
}

const q = computed(() => boundarySearch.value);
</script>

<template>
  <Transition name="panel-slide">
    <div v-if="hierarchyPanelOpen" class="geo-hierarchy-panel">
      <div class="panel-header">
        <span class="panel-title">Geo Hierarchy</span>
        <button class="close-btn" @click="hierarchyPanelOpen = false">✕</button>
      </div>

      <div class="search-row">
        <input v-model="boundarySearch" placeholder="Search boundaries…" class="search-input" />
      </div>

      <div class="panel-body">
        <div v-if="!filteredHierarchy" class="empty-msg">No hierarchy data</div>
        <div v-else>
          <div
            v-for="state in filteredHierarchy.states"
            :key="state.pcode"
            class="state-node"
          >
            <div class="state-row" @click="clickState(state)">
              <span class="expand-icon">{{ expandedStates.has(state.pcode) ? '▾' : '▸' }}</span>
              <span class="state-name" v-html="highlight(state.name, q)"></span>
              <span v-if="state.level_label" class="level-badge">{{ state.level_label }}</span>
              <span class="pcode-badge">{{ state.pcode }}</span>
            </div>

            <template v-if="expandedStates.has(state.pcode)">
              <!-- Children: zones first, then LGAs -->
              <template v-if="state.children?.length">
                <div
                  v-for="child in state.children"
                  :key="isZone(child) ? (child as HierarchyZone).zone_pcode : (child as any).pcode"
                  class="child-row"
                  :class="{ 'is-zone': isZone(child) }"
                  @click="isZone(child) ? clickZone(child as HierarchyZone) : clickLGA(state, child as HierarchyLGA)"
                >
                  <span v-if="isZone(child)" class="zone-dot" :style="{ background: (child as HierarchyZone).color ?? '#a78bfa' }"></span>
                  <span v-else class="lga-dot"></span>
                  <span v-html="highlight(isZone(child) ? (child as HierarchyZone).zone_name : (child as HierarchyLGA).name, q)"></span>
                  <span v-if="!isZone(child) && (child as HierarchyLGA).level_label" class="level-badge child-level">{{ (child as HierarchyLGA).level_label }}</span>
                </div>
              </template>
              <template v-else-if="state.lgas?.length">
                <div
                  v-for="lga in state.lgas"
                  :key="lga.pcode"
                  class="child-row"
                  @click="clickLGA(state, lga)"
                >
                  <span class="lga-dot"></span>
                  <span v-html="highlight(lga.name, q)"></span>
                  <span v-if="lga.level_label" class="level-badge child-level">{{ lga.level_label }}</span>
                </div>
              </template>
            </template>
          </div>

          <div v-if="filteredHierarchy.states.length === 0" class="empty-msg">No results</div>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.geo-hierarchy-panel {
  position: absolute;
  top: 10px;
  left: 130px;
  width: 280px;
  max-height: 60vh;
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 10px;
  box-shadow: 0 4px 20px rgba(0,0,0,0.12);
  display: flex;
  flex-direction: column;
  z-index: 10;
  overflow: hidden;
}

.panel-header {
  display: flex; align-items: center;
  padding: 10px 12px 6px;
  border-bottom: 1px solid #f1f5f9;
  flex-shrink: 0;
}
.panel-title { font-size: 13px; font-weight: 700; color: #0f172a; flex: 1; }
.close-btn {
  background: none; border: none; cursor: pointer; color: #94a3b8;
  font-size: 12px; padding: 2px 4px; border-radius: 3px;
}
.close-btn:hover { background: #f1f5f9; color: #475569; }

.search-row { padding: 6px 12px; flex-shrink: 0; }
.search-input {
  width: 100%; box-sizing: border-box;
  border: 1px solid #e2e8f0; border-radius: 6px;
  padding: 5px 8px; font-size: 12px; color: #0f172a;
}
.search-input:focus { outline: none; border-color: #3b82f6; }

.panel-body { overflow-y: auto; flex: 1; padding: 4px 0 8px; }

.state-node { }
.state-row {
  display: flex; align-items: center; gap: 6px;
  padding: 5px 12px; cursor: pointer;
  transition: background 0.1s;
}
.state-row:hover { background: #f8fafc; }
.expand-icon { font-size: 9px; color: #94a3b8; flex-shrink: 0; }
.state-name { flex: 1; font-size: 13px; font-weight: 600; color: #1e293b; }
.pcode-badge { font-size: 10px; color: #94a3b8; flex-shrink: 0; }
.level-badge {
  font-size: 10px; color: #3b82f6; background: #eff6ff;
  border: 1px solid #bfdbfe; border-radius: 4px;
  padding: 0 5px; flex-shrink: 0; white-space: nowrap;
}
.level-badge.child-level { color: #6366f1; background: #eef2ff; border-color: #c7d2fe; }

.child-row {
  display: flex; align-items: center; gap: 7px;
  padding: 3px 12px 3px 26px; cursor: pointer; font-size: 12px; color: #334155;
  transition: background 0.1s;
}
.child-row:hover { background: #f1f5f9; }
.child-row.is-zone { font-weight: 500; }

.zone-dot { width: 8px; height: 8px; border-radius: 2px; flex-shrink: 0; }
.lga-dot { width: 6px; height: 6px; border-radius: 50%; background: #cbd5e1; flex-shrink: 0; }

.empty-msg { font-size: 12px; color: #94a3b8; text-align: center; padding: 12px; }

/* Search highlight */
:deep(mark) { background: #fef9c3; color: inherit; border-radius: 2px; }

/* Slide animation */
.panel-slide-enter-active, .panel-slide-leave-active { transition: all 0.22s ease; }
.panel-slide-enter-from, .panel-slide-leave-to { opacity: 0; transform: translateY(-8px) scale(0.98); }
</style>
