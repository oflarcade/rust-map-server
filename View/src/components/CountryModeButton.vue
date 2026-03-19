<script setup lang="ts">
import { useCountryMode } from '../composables/useCountryMode';
import { useTileInspector } from '../composables/useTileInspector';

const { isCountryMode, countryTenants, tenantColors, visibleCountryTenants, toggleCountryTenant, loadCountryOverlays, clearCountryOverlays } = useCountryMode();
const { hierarchyPanelOpen, layersPanelOpen, filteredHierarchy, boundarySearch, flyToHierarchyItem, highlightBoundary, highlight, baseControls, boundaryControls, toggleControl } = useTileInspector();

import { ref, computed } from 'vue';

const expandedNodes = ref<Set<string>>(new Set());
function toggleNode(pcode: string) {
  const next = new Set(expandedNodes.value);
  if (next.has(pcode)) next.delete(pcode); else next.add(pcode);
  expandedNodes.value = next;
}
function clickState(state: any) {
  toggleNode(state.pcode);
  flyToHierarchyItem(state);
  highlightBoundary({ pcode: state.pcode, level: 'state', name: state.name });
}
function clickChild(child: any, state: any) {
  if (child.children?.length) toggleNode(child.pcode ?? child.zone_pcode);
  if (isZone(child)) {
    highlightBoundary({ pcode: child.zone_pcode, level: 'zone', name: child.zone_name });
  } else {
    flyToHierarchyItem(state, child);
    highlightBoundary({ pcode: child.pcode, level: 'lga', name: child.name });
  }
}
function clickLeaf(child: any, state: any) {
  if (isZone(child)) {
    highlightBoundary({ pcode: child.zone_pcode, level: 'zone', name: child.zone_name });
  } else {
    highlightBoundary({ pcode: child.pcode, level: 'lga', name: child.name });
  }
}
function isZone(child: any) {
  return child.is_zone === true || child.zone_pcode !== undefined;
}
const q = computed(() => boundarySearch.value);

async function toggleMode() {
  isCountryMode.value = !isCountryMode.value;
  if (isCountryMode.value) await loadCountryOverlays();
  else clearCountryOverlays();
}
</script>

<template>
  <div class="map-controls">

    <!-- ── Country row (button + tenant tags inline) ── -->
    <div class="control-row">
      <button class="map-btn" :class="{ active: isCountryMode }" @click="toggleMode">
        Country
        <span class="chevron">{{ isCountryMode ? '▾' : '▸' }}</span>
      </button>

      <TransitionGroup name="tag" tag="div" class="tag-list">
        <button
          v-if="isCountryMode"
          v-for="t in countryTenants"
          :key="t.id"
          class="tenant-tag"
          :class="{ hidden: !visibleCountryTenants.has(t.id) }"
          :style="{ borderColor: tenantColors[t.id] }"
          @click="toggleCountryTenant(t.id)"
          :title="t.name"
        >
          <span class="tag-dot" :style="{ background: tenantColors[t.id] }"></span>
          <span class="tag-name">{{ t.name }}</span>
        </button>
      </TransitionGroup>
    </div>

    <!-- ── Geo Hierarchy + Layers row ── -->
    <div class="control-row">
      <button
        class="map-btn"
        :class="{ active: hierarchyPanelOpen }"
        @click="hierarchyPanelOpen = !hierarchyPanelOpen; layersPanelOpen = false"
      >
        Geo Hierarchy
        <span class="chevron">{{ hierarchyPanelOpen ? '▾' : '▸' }}</span>
      </button>
      <button
        class="map-btn"
        :class="{ active: layersPanelOpen }"
        @click="layersPanelOpen = !layersPanelOpen; hierarchyPanelOpen = false"
      >
        <svg class="layers-icon" viewBox="0 0 14 11" width="13" height="11" fill="currentColor">
          <rect y="0"   width="14" height="2.5" rx="1"/>
          <rect y="4.2" width="14" height="2.5" rx="1"/>
          <rect y="8.5" width="14" height="2.5" rx="1"/>
        </svg>
        Layers
        <span class="chevron">{{ layersPanelOpen ? '▾' : '▸' }}</span>
      </button>
    </div>

    <!-- Geo Hierarchy panel (inline below row) -->
    <Transition name="panel-slide">
      <div v-if="hierarchyPanelOpen" class="inline-panel">
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
            <div v-for="state in filteredHierarchy.states" :key="state.pcode" class="state-node">
              <!-- Level 1: Province/State -->
              <div class="state-row" @click="clickState(state)">
                <span class="expand-icon">{{ expandedNodes.has(state.pcode) ? '▾' : '▸' }}</span>
                <span class="state-name" v-html="highlight(state.name, q)"></span>
                <span v-if="state.level_label" class="level-badge">{{ state.level_label }}</span>
                <span class="pcode-badge">{{ state.pcode }}</span>
              </div>

              <template v-if="expandedNodes.has(state.pcode)">
                <!-- Use children[] if present (supports 3+ levels), else lgas[] -->
                <template v-if="state.children?.length">
                  <template v-for="child in state.children" :key="isZone(child) ? child.zone_pcode : child.pcode">
                    <!-- Level 2 row -->
                    <div
                      class="child-row depth-1"
                      :class="{ 'is-zone': isZone(child), 'has-children': child.children?.length }"
                      @click="clickChild(child, state)"
                    >
                      <span v-if="isZone(child)" class="zone-dot" :style="{ background: child.color ?? '#a78bfa' }"></span>
                      <span v-else-if="child.children?.length" class="expand-icon sub">{{ expandedNodes.has(child.pcode) ? '▾' : '▸' }}</span>
                      <span v-else class="lga-dot"></span>
                      <span v-html="highlight(isZone(child) ? child.zone_name : child.name, q)"></span>
                      <span v-if="child.level_label" class="level-badge child-level">{{ child.level_label }}</span>
                    </div>
                    <!-- Level 3: grandchildren (e.g. Rwanda Sectors) -->
                    <template v-if="child.children?.length && expandedNodes.has(child.pcode ?? child.zone_pcode)">
                      <div
                        v-for="gc in child.children"
                        :key="isZone(gc) ? gc.zone_pcode : gc.pcode"
                        class="child-row depth-2"
                        @click="clickLeaf(gc, state)"
                      >
                        <span class="lga-dot small"></span>
                        <span v-html="highlight(isZone(gc) ? gc.zone_name : gc.name, q)"></span>
                        <span v-if="gc.level_label" class="level-badge child-level">{{ gc.level_label }}</span>
                      </div>
                    </template>
                  </template>
                </template>
                <template v-else-if="state.lgas?.length">
                  <div
                    v-for="lga in state.lgas"
                    :key="lga.pcode"
                    class="child-row depth-1"
                    @click="clickChild(lga, state)"
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

    <!-- Layers panel (inline below row) -->
    <Transition name="panel-slide">
      <div v-if="layersPanelOpen" class="inline-panel">
        <div class="panel-header">
          <span class="panel-title">Layers</span>
          <button class="close-btn" @click="layersPanelOpen = false">✕</button>
        </div>
        <div class="panel-body-layers">
          <div class="group-label">Base</div>
          <label v-for="row in baseControls" :key="row.id" class="layer-row">
            <input type="checkbox" :checked="row.visible" @change="toggleControl(row)" />
            <span>{{ row.label }}</span>
          </label>
          <div class="group-label" style="margin-top:8px">Boundaries</div>
          <label v-for="row in boundaryControls" :key="row.id" class="layer-row">
            <input type="checkbox" :checked="row.visible" @change="toggleControl(row)" />
            <span>{{ row.label }}</span>
          </label>
        </div>
      </div>
    </Transition>

  </div>
</template>

<style scoped>
.map-controls {
  position: absolute;
  top: 10px;
  left: 10px;
  display: flex;
  flex-direction: column;
  gap: 5px;
  z-index: 10;
  max-height: calc(100vh - 20px);
  overflow-y: auto;
}

.control-row {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 6px;
}

.map-btn {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 12px;
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 7px;
  font-size: 12px;
  font-weight: 700;
  color: #334155;
  box-shadow: 0 1px 4px rgba(0,0,0,0.10);
  white-space: nowrap;
  transition: background 0.12s, border-color 0.12s;
  cursor: pointer;
}
.map-btn:hover { background: #f8fafc; border-color: #cbd5e1; }
.map-btn.active { background: #eff6ff; border-color: #93c5fd; color: #1d4ed8; }

.chevron { font-size: 9px; color: #94a3b8; }
.layers-icon { flex-shrink: 0; opacity: 0.6; }

/* Tenant tags */
.tag-list {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 5px;
  flex-wrap: nowrap;
}

.tenant-tag {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 4px 10px 4px 7px;
  background: #fff;
  border: 1.5px solid;
  border-radius: 20px;
  font-size: 11px;
  font-weight: 600;
  cursor: pointer;
  white-space: nowrap;
  box-shadow: 0 1px 3px rgba(0,0,0,0.08);
  color: #1e293b;
  transition: opacity 0.15s;
}
.tenant-tag.hidden { opacity: 0.35; }
.tenant-tag:hover { opacity: 0.8; }
.tag-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }

.tag-enter-active { transition: all 0.18s ease; }
.tag-leave-active { transition: all 0.14s ease; }
.tag-enter-from, .tag-leave-to { opacity: 0; transform: translateX(-6px) scale(0.9); }

/* Inline panels */
.inline-panel {
  width: 260px;
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 10px;
  box-shadow: 0 4px 20px rgba(0,0,0,0.12);
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

/* Geo Hierarchy panel body */
.search-row { padding: 6px 12px; }
.search-input {
  width: 100%; box-sizing: border-box;
  border: 1px solid #e2e8f0; border-radius: 6px;
  padding: 5px 8px; font-size: 12px; color: #0f172a;
}
.search-input:focus { outline: none; border-color: #3b82f6; }

.panel-body { overflow-y: auto; max-height: 40vh; padding: 4px 0 8px; }

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
  cursor: pointer; font-size: 12px; color: #334155;
  transition: background 0.1s; padding: 3px 12px;
}
.child-row.depth-1 { padding-left: 26px; }
.child-row.depth-2 { padding-left: 40px; font-size: 11px; color: #475569; }
.child-row:hover { background: #f1f5f9; }
.child-row.is-zone { font-weight: 500; }
.child-row.has-children { font-weight: 500; }
.zone-dot { width: 8px; height: 8px; border-radius: 2px; flex-shrink: 0; }
.lga-dot { width: 6px; height: 6px; border-radius: 50%; background: #cbd5e1; flex-shrink: 0; }
.lga-dot.small { width: 4px; height: 4px; }
.expand-icon.sub { font-size: 9px; color: #94a3b8; flex-shrink: 0; }
.empty-msg { font-size: 12px; color: #94a3b8; text-align: center; padding: 12px; }
:deep(mark) { background: #fef9c3; color: inherit; border-radius: 2px; }

/* Layers panel body */
.panel-body-layers { padding: 8px 12px 12px; display: flex; flex-direction: column; gap: 4px; }
.group-label {
  font-size: 10px; font-weight: 700; color: #94a3b8;
  text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 2px;
}
.layer-row {
  display: flex; align-items: center; gap: 8px;
  font-size: 12px; color: #334155; cursor: pointer; padding: 2px 0;
}
.layer-row:hover { color: #0f172a; }

/* Slide animation */
.panel-slide-enter-active, .panel-slide-leave-active { transition: all 0.22s ease; }
.panel-slide-enter-from, .panel-slide-leave-to { opacity: 0; transform: translateY(-6px) scale(0.98); }
</style>
