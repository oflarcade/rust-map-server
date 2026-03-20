<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import { useCountryMode } from '../composables/useCountryMode';
import { useTileInspector } from '../composables/useTileInspector';
import { useBoundarySearch } from '../composables/useBoundarySearch';
import { useMapInteraction } from '../composables/useMapInteraction';
import { useMapLayers } from '../composables/useMapLayers';
import Button from 'primevue/button';
import InputText from 'primevue/inputtext';
import Tree from 'primevue/tree';
import HierarchyEditorPanel from './HierarchyEditorPanel.vue';
import Tag from 'primevue/tag';
import type { TreeNode } from 'primevue/treenode';
import type { HierarchyChild, HierarchyZone, HierarchyAdmNode, HierarchyState } from '../types/boundary';

const { isCountryMode, countryTenants, tenantColors, visibleCountryTenants, toggleCountryTenant, loadCountryOverlays, clearCountryOverlays } = useCountryMode();
const { hierarchyPanelOpen, layersPanelOpen, hierarchyEditorOpen, resizeMap } = useTileInspector();

watch(hierarchyEditorOpen, () => {
  setTimeout(() => resizeMap(), 280);
});
const { filteredHierarchy, boundarySearch, boundaryHierarchy } = useBoundarySearch();
const { flyToHierarchyItem, highlightBoundary, highlight } = useMapInteraction();
const { baseControls, boundaryControls, toggleControl } = useMapLayers();

// ---------------------------------------------------------------------------
// Tree nodes for the inline Geo Hierarchy panel
// ---------------------------------------------------------------------------

const selectionKeys = ref<Record<string, boolean>>({});

function buildChildNode(child: HierarchyChild): TreeNode {
  if ('zone_pcode' in child) {
    const zone = child as HierarchyZone;
    return {
      key: zone.zone_pcode,
      label: zone.zone_name,
      data: {
        type: 'zone',
        pcode: zone.zone_pcode,
        name: zone.zone_name,
        color: zone.color,
        level_label: zone.zone_type_label,
      },
      children: zone.children ? zone.children.map(buildChildNode) : [],
      leaf: !zone.children?.length,
    };
  } else {
    const adm = child as HierarchyAdmNode;
    return {
      key: adm.pcode,
      label: adm.name,
      data: {
        type: 'adm',
        pcode: adm.pcode,
        name: adm.name,
        level_label: adm.level_label,
      },
      children: adm.children ? adm.children.map((c) => buildChildNode(c as HierarchyChild)) : [],
      leaf: !adm.children?.length,
    };
  }
}

function buildStateChildren(state: HierarchyState): TreeNode[] {
  const children: TreeNode[] = [];
  if (state.children && state.children.length > 0) {
    for (const child of state.children) {
      children.push(buildChildNode(child));
    }
  } else {
    for (const lga of state.lgas) {
      children.push({
        key: lga.pcode,
        label: lga.name,
        data: {
          type: 'lga',
          pcode: lga.pcode,
          name: lga.name,
          level_label: lga.level_label,
        },
        leaf: true,
      });
    }
  }
  return children;
}

const treeNodes = computed<TreeNode[]>(() => {
  if (!filteredHierarchy.value) return [];
  return filteredHierarchy.value.states.map((state) => ({
    key: state.pcode,
    label: state.name,
    data: {
      type: 'state',
      pcode: state.pcode,
      name: state.name,
      level_label: state.level_label,
    },
    children: buildStateChildren(state),
  }));
});

function onNodeSelect(node: TreeNode) {
  const d = node.data as { type: string; pcode: string; name: string };
  if (d.type === 'state') {
    const state = boundaryHierarchy.value?.states.find((s) => s.pcode === d.pcode);
    if (state) flyToHierarchyItem(state);
    highlightBoundary({ pcode: d.pcode, level: 'state', name: d.name });
  } else if (d.type === 'zone') {
    highlightBoundary({ pcode: d.pcode, level: 'zone' });
  } else {
    const state = boundaryHierarchy.value?.states.find((s) =>
      s.lgas.some((l) => l.pcode === d.pcode),
    );
    highlightBoundary({ pcode: d.pcode, level: 'lga', name: d.name });
    if (state) {
      const lga = state.lgas.find((l) => l.pcode === d.pcode);
      if (lga) flyToHierarchyItem(state, lga);
    }
  }
}

// ---------------------------------------------------------------------------
// Layer toggle rows — ToggleSwitch needs a boolean model per row
// ---------------------------------------------------------------------------

async function toggleMode() {
  isCountryMode.value = !isCountryMode.value;
  if (isCountryMode.value) await loadCountryOverlays();
  else clearCountryOverlays();
}
</script>

<template>
  <div class="absolute top-2 left-2 z-20 flex flex-col gap-1.5 max-h-[calc(100vh-16px)] overflow-y-auto">

    <!-- ── Country row (button + tenant tags inline) ── -->
    <div class="flex flex-wrap items-center gap-1.5">
      <button class="map-btn" :class="{ 'map-btn--active': isCountryMode }" @click="toggleMode">
        <i class="pi pi-globe" style="font-size:10px"></i>
        Country
        <span class="map-btn-chevron">{{ isCountryMode ? '▾' : '▸' }}</span>
      </button>

      <TransitionGroup name="tag" tag="div" class="flex flex-row flex-wrap items-center gap-1">
        <button
          v-if="isCountryMode"
          v-for="t in countryTenants"
          :key="t.id"
          class="tenant-tag"
          :class="{ 'tenant-tag--hidden': !visibleCountryTenants.has(t.id) }"
          :style="{ '--tag-color': tenantColors[t.id] }"
          @click="toggleCountryTenant(t.id)"
          :title="t.name"
        >
          <span class="tenant-tag-dot" :style="{ background: tenantColors[t.id] }"></span>
          {{ t.name }}
        </button>
      </TransitionGroup>
    </div>

    <!-- ── Geo Hierarchy + Layers row ── -->
    <div class="flex flex-wrap items-center gap-1.5">
      <button class="map-btn" :class="{ 'map-btn--active': hierarchyPanelOpen }"
              @click="hierarchyPanelOpen = !hierarchyPanelOpen; layersPanelOpen = false">
        <i class="pi pi-sitemap" style="font-size:10px"></i>
        Geo Hierarchy
        <span class="map-btn-chevron">{{ hierarchyPanelOpen ? '▾' : '▸' }}</span>
      </button>
      <button class="map-btn" :class="{ 'map-btn--active': layersPanelOpen }"
              @click="layersPanelOpen = !layersPanelOpen; hierarchyPanelOpen = false">
        <svg style="width:12px;height:10px;flex-shrink:0" viewBox="0 0 14 11" fill="currentColor">
          <rect y="0"   width="14" height="2.5" rx="1"/>
          <rect y="4.2" width="14" height="2.5" rx="1"/>
          <rect y="8.5" width="14" height="2.5" rx="1"/>
        </svg>
        Layers
        <span class="map-btn-chevron">{{ layersPanelOpen ? '▾' : '▸' }}</span>
      </button>
      <button class="map-btn" :class="{ 'map-btn--active': hierarchyEditorOpen }"
              @click="hierarchyEditorOpen = !hierarchyEditorOpen; hierarchyPanelOpen = false; layersPanelOpen = false">
        <i class="pi pi-pen-to-square" style="font-size:10px"></i>
        Hierarchy Editor
        <span class="map-btn-chevron">{{ hierarchyEditorOpen ? '▾' : '▸' }}</span>
      </button>
    </div>

    <!-- Geo Hierarchy panel (inline below row) -->
    <Transition name="panel-slide">
      <div v-if="hierarchyPanelOpen" class="map-panel">
        <div class="map-panel-header">
          <span>Geo Hierarchy</span>
          <button class="panel-close-btn" @click="hierarchyPanelOpen = false">
            <i class="pi pi-times"></i>
          </button>
        </div>
        <InputText v-model="boundarySearch" placeholder="Search boundaries…" class="w-full !text-sm mb-2" />
        <div class="overflow-y-auto max-h-[40vh]">
          <div v-if="!filteredHierarchy" class="text-xs text-slate-400 text-center py-3">No hierarchy data</div>
          <template v-else>
            <Tree
              :value="treeNodes"
              selectionMode="single"
              v-model:selectionKeys="selectionKeys"
              @node-select="onNodeSelect"
              class="w-full !text-xs !border-0 !p-0"
            >
              <template #default="{ node }">
                <span class="flex items-center gap-1">
                  <span
                    v-if="node.data.color"
                    class="inline-block w-2 h-2 rounded-full flex-shrink-0"
                    :style="{ background: node.data.color }"
                  ></span>
                  <Tag
                    v-if="node.data.level_label"
                    severity="secondary"
                    class="!text-[9px] !py-0 !px-1 flex-shrink-0"
                  >{{ node.data.level_label }}</Tag>
                  <span v-html="highlight(node.data.name, boundarySearch)"></span>
                </span>
              </template>
            </Tree>
            <div v-if="filteredHierarchy.states.length === 0" class="text-xs text-slate-400 text-center py-3">No results</div>
          </template>
        </div>
      </div>
    </Transition>

    <!-- Layers panel (inline below row) -->
    <Transition name="panel-slide">
      <div v-if="layersPanelOpen" class="map-panel">
        <div class="map-panel-header">
          <span>Layers</span>
          <button class="panel-close-btn" @click="layersPanelOpen = false">
            <i class="pi pi-times"></i>
          </button>
        </div>
        <div class="flex flex-col gap-0.5">
          <div class="text-[10px] font-bold text-slate-400 uppercase tracking-wider mb-1">Base</div>
          <label v-for="row in baseControls" :key="row.id"
            class="flex items-center gap-2.5 px-1.5 py-1 rounded-md cursor-pointer transition-colors hover:bg-slate-50"
            :class="row.visible ? 'text-slate-800' : 'text-slate-400'"
          >
            <!-- Compact pill toggle -->
            <span
              class="relative flex-shrink-0 w-7 h-4 rounded-full transition-colors duration-150"
              :class="row.visible ? 'bg-blue-500' : 'bg-slate-200'"
              @click.prevent="toggleControl(row)"
            >
              <span
                class="absolute top-0.5 left-0.5 w-3 h-3 bg-white rounded-full shadow-sm transition-transform duration-150"
                :class="row.visible ? 'translate-x-3' : 'translate-x-0'"
              />
            </span>
            <span class="text-xs select-none">{{ row.label }}</span>
          </label>
          <div class="text-[10px] font-bold text-slate-400 uppercase tracking-wider mb-1 mt-2.5">Boundaries</div>
          <label v-for="row in boundaryControls" :key="row.id"
            class="flex items-center gap-2.5 px-1.5 py-1 rounded-md cursor-pointer transition-colors hover:bg-slate-50"
            :class="row.visible ? 'text-slate-800' : 'text-slate-400'"
          >
            <span
              class="relative flex-shrink-0 w-7 h-4 rounded-full transition-colors duration-150"
              :class="row.visible ? 'bg-blue-500' : 'bg-slate-200'"
              @click.prevent="toggleControl(row)"
            >
              <span
                class="absolute top-0.5 left-0.5 w-3 h-3 bg-white rounded-full shadow-sm transition-transform duration-150"
                :class="row.visible ? 'translate-x-3' : 'translate-x-0'"
              />
            </span>
            <span class="text-xs select-none">{{ row.label }}</span>
          </label>
        </div>
      </div>
    </Transition>

    <!-- Hierarchy editor — compact sheet under control rows (map stays visible) -->
    <Transition name="panel-slide">
      <HierarchyEditorPanel v-if="hierarchyEditorOpen" />
    </Transition>

  </div>
</template>

<style scoped>
/* ── Map control buttons ─────────────────────────────────────────────── */
.map-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 6px 11px;
  background: #ffffff;
  border: none;
  border-radius: 8px;
  font-size: 11.5px;
  font-weight: 500;
  color: #334155;
  cursor: pointer;
  white-space: nowrap;
  user-select: none;
  box-shadow: 0 1px 3px rgba(0,0,0,0.16), 0 0 0 1px rgba(0,0,0,0.06);
  transition: background 0.12s, box-shadow 0.12s, transform 0.1s;
}
.map-btn:hover {
  background: #f8fafc;
  box-shadow: 0 2px 8px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.07);
  transform: translateY(-0.5px);
}
.map-btn--active {
  background: #eff6ff;
  color: #1d4ed8;
  box-shadow: 0 1px 4px rgba(59,130,246,0.22), 0 0 0 1.5px rgba(59,130,246,0.35);
}
.map-btn--active:hover {
  background: #dbeafe;
}
.map-btn-chevron {
  font-size: 9px;
  opacity: 0.55;
  margin-left: 1px;
}

/* ── Tenant tag pills ───────────────────────────────────────────────── */
.tenant-tag {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 3px 9px 3px 6px;
  background: #ffffff;
  border: 1.5px solid var(--tag-color, #94a3b8);
  border-radius: 20px;
  font-size: 11px;
  font-weight: 500;
  color: #334155;
  cursor: pointer;
  white-space: nowrap;
  box-shadow: 0 1px 3px rgba(0,0,0,0.10);
  transition: opacity 0.15s, box-shadow 0.12s;
}
.tenant-tag:hover { box-shadow: 0 2px 6px rgba(0,0,0,0.14); }
.tenant-tag--hidden { opacity: 0.35; }
.tenant-tag-dot {
  width: 8px; height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}

/* ── Floating panel ─────────────────────────────────────────────────── */
.map-panel {
  background: rgba(255,255,255,0.97);
  backdrop-filter: blur(8px);
  -webkit-backdrop-filter: blur(8px);
  border-radius: 12px;
  box-shadow: 0 4px 24px rgba(0,0,0,0.13), 0 0 0 1px rgba(0,0,0,0.06);
  padding: 14px;
  width: 272px;
  overflow: hidden;
}
.map-panel-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 10px;
  font-size: 12px;
  font-weight: 600;
  color: #1e293b;
  letter-spacing: 0.01em;
}
.panel-close-btn {
  width: 22px; height: 22px;
  display: flex; align-items: center; justify-content: center;
  background: #f1f5f9;
  border: none;
  border-radius: 6px;
  color: #64748b;
  font-size: 9px;
  cursor: pointer;
  transition: background 0.1s, color 0.1s;
}
.panel-close-btn:hover { background: #e2e8f0; color: #1e293b; }

/* ── Transitions ────────────────────────────────────────────────────── */
.tag-enter-active { transition: all 0.18s ease; }
.tag-leave-active { transition: all 0.14s ease; }
.tag-enter-from, .tag-leave-to { opacity: 0; transform: translateX(-6px) scale(0.9); }

.panel-slide-enter-active,
.panel-slide-leave-active { transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); }
.panel-slide-enter-from,
.panel-slide-leave-to { opacity: 0; transform: translateY(-8px) scale(0.97); }

:deep(mark) {
  background: #fef9c3;
  color: inherit;
  border-radius: 2px;
}

/* Tree hierarchy indentation — every nested level gets 1.25rem indent + guide line */
:deep(.p-tree-node-children) {
  padding-left: 1.25rem !important;
  margin-left: 0.5rem;
  border-left: 1px solid #e2e8f0;
}
</style>
