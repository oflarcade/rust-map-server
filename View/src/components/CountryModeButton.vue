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
import Select from 'primevue/select';
import HierarchyEditorPanel from './HierarchyEditorPanel.vue';
import Tag from 'primevue/tag';
import type { TenantConfig } from '../types/tenant';
import type { TreeNode } from 'primevue/treenode';
import type { HierarchyChild, HierarchyZone, HierarchyAdmNode, HierarchyState } from '../types/boundary';

const { isCountryMode, countryTenants, tenantColors, visibleCountryTenants, toggleCountryTenant, loadCountryOverlays, clearCountryOverlays } = useCountryMode();
const {
  hierarchyPanelOpen,
  layersPanelOpen,
  hierarchyEditorOpen,
  resizeMap,
  selectedTenantId,
  tenantList,
  currentTenant,
  openAddTenantWizard,
} = useTileInspector();

const CC_COLORS: Record<string, string> = {
  NG: '#16a34a',
  KE: '#2563eb',
  UG: '#7c3aed',
  RW: '#db2777',
  LR: '#ea580c',
  IN: '#f59e0b',
  CF: '#64748b',
};

const groupedTenants = computed(() => {
  const groups: Record<string, TenantConfig[]> = {};
  for (const t of tenantList.value) {
    if (!groups[t.countryCode]) groups[t.countryCode] = [];
    groups[t.countryCode].push(t);
  }
  return Object.entries(groups)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([code, items]) => ({ label: code, items }));
});

function ccColor(code: string): string {
  return CC_COLORS[code] ?? '#64748b';
}

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
    for (const adm2 of state.adm2s) {
      children.push({
        key: adm2.pcode,
        label: adm2.name,
        data: {
          type: 'adm2',
          pcode: adm2.pcode,
          name: adm2.name,
          level_label: adm2.level_label,
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

function findInTree(children: any[], pcode: string): any {
  for (const child of children ?? []) {
    if ((child.pcode ?? child.zone_pcode) === pcode) return child;
    const found = findInTree(child.children ?? [], pcode);
    if (found) return found;
  }
  return null;
}

function onNodeSelect(node: TreeNode) {
  const d = node.data as { type: string; pcode: string; name: string };
  if (d.type === 'state') {
    const state = boundaryHierarchy.value?.states.find((s) => s.pcode === d.pcode);
    if (state) flyToHierarchyItem(state);
    highlightBoundary({ pcode: d.pcode, level: 'state', name: d.name });
  } else if (d.type === 'zone') {
    highlightBoundary({ pcode: d.pcode, level: 'zone' });
  } else {
    // leaf boundary node — may be an ungrouped adm2 or a node deep in the children tree
    const state = boundaryHierarchy.value?.states.find((s) =>
      s.adm2s.some((a) => a.pcode === d.pcode) ||
      findInTree(s.children, d.pcode) != null,
    );
    highlightBoundary({ pcode: d.pcode, level: 'adm2', name: d.name });
    if (state) {
      const item = state.adm2s.find((a) => a.pcode === d.pcode)
                ?? findInTree(state.children, d.pcode);
      if (item) flyToHierarchyItem(state, item);
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

    <!-- ── Row 1: Country + tenant selector (+ multi-country tags when Country mode on) ── -->
    <div class="flex flex-wrap items-center gap-1.5">
      <button class="map-btn" :class="{ 'map-btn--active': isCountryMode }" @click="toggleMode">
        <i class="pi pi-globe" style="font-size:10px"></i>
        Country
        <span class="map-btn-chevron">{{ isCountryMode ? '▾' : '▸' }}</span>
      </button>

      <Select
        v-model="selectedTenantId"
        :options="groupedTenants"
        optionGroupLabel="label"
        optionGroupChildren="items"
        optionValue="id"
        :optionLabel="(t: TenantConfig) => t.name"
        class="tenant-map-select"
        :pt="{ root: { class: 'min-w-[10.5rem] max-w-[240px]' } }"
        title="Active program / tenant"
      >
        <template #value="{ value }">
          <template v-if="value">
            <div class="flex items-center gap-1.5 py-0.5">
              <span
                class="inline-flex items-center justify-center rounded px-1 py-0.5 text-[9px] font-bold text-white leading-none"
                :style="{ backgroundColor: ccColor(currentTenant.countryCode) }"
              >{{ currentTenant.countryCode }}</span>
              <span class="text-xs text-slate-800 truncate max-w-[11rem]">{{ currentTenant.name }}</span>
            </div>
          </template>
          <span v-else class="text-xs text-slate-400">Program…</span>
        </template>
        <template #optiongroup="{ option: group }">
          <div class="flex items-center gap-2 px-1 py-0.5">
            <span
              class="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-bold text-white leading-none"
              :style="{ backgroundColor: ccColor(group.label) }"
            >{{ group.label }}</span>
            <span class="text-[10px] font-semibold text-slate-400 uppercase tracking-wider">
              {{ group.items.length }} tenant{{ group.items.length !== 1 ? 's' : '' }}
            </span>
          </div>
        </template>
        <template #option="{ option }">
          <div class="flex items-center gap-2">
            <span
              class="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-medium text-slate-500 bg-slate-100 leading-none tabular-nums min-w-[20px]"
            >{{ option.id }}</span>
            <span class="text-xs text-slate-700 truncate">{{ option.name }}</span>
          </div>
        </template>
      </Select>

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

    <!-- ── Row 2: Add tenant + Geo Hierarchy / Layers / Hierarchy Editor ── -->
    <div class="flex flex-wrap items-center gap-1.5">
      <button
        type="button"
        class="map-btn map-btn--emphasis"
        title="Add a new tenant"
        @click="openAddTenantWizard"
      >
        <i class="pi pi-plus-circle" style="font-size:10px"></i>
        Add tenant
      </button>
      <button
        class="map-btn"
        :class="{ 'map-btn--active': hierarchyPanelOpen }"
        @click="
          hierarchyPanelOpen = !hierarchyPanelOpen;
          layersPanelOpen = false;
          hierarchyEditorOpen = false;
        "
      >
        <i class="pi pi-sitemap" style="font-size:10px"></i>
        Geo Hierarchy
        <span class="map-btn-chevron">{{ hierarchyPanelOpen ? '▾' : '▸' }}</span>
      </button>
      <button
        class="map-btn"
        :class="{ 'map-btn--active': layersPanelOpen }"
        @click="
          layersPanelOpen = !layersPanelOpen;
          hierarchyPanelOpen = false;
          hierarchyEditorOpen = false;
        "
      >
        <svg style="width:12px;height:10px;flex-shrink:0" viewBox="0 0 14 11" fill="currentColor">
          <rect y="0" width="14" height="2.5" rx="1" />
          <rect y="4.2" width="14" height="2.5" rx="1" />
          <rect y="8.5" width="14" height="2.5" rx="1" />
        </svg>
        Layers
        <span class="map-btn-chevron">{{ layersPanelOpen ? '▾' : '▸' }}</span>
      </button>
      <button
        class="map-btn"
        :class="{ 'map-btn--active': hierarchyEditorOpen }"
        @click="
          hierarchyEditorOpen = !hierarchyEditorOpen;
          hierarchyPanelOpen = false;
          layersPanelOpen = false;
        "
      >
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
                <span class="flex items-center gap-1.5 min-w-0 w-full">
                  <span
                    v-if="node.data.color"
                    class="inline-block w-2 h-2 rounded-full flex-shrink-0"
                    :style="{ background: node.data.color }"
                  />
                  <span class="flex flex-col min-w-0 flex-1 leading-tight">
                    <span class="truncate text-xs font-medium text-slate-800" v-html="highlight(node.data.name, boundarySearch)" />
                    <span class="flex items-center gap-1 mt-0.5">
                      <Tag
                        v-if="node.data.level_label"
                        severity="secondary"
                        class="!text-[8px] !py-0 !px-1 flex-shrink-0"
                      >{{ node.data.level_label }}</Tag>
                      <span class="text-[9px] text-slate-400 font-mono truncate">{{ node.data.pcode }}</span>
                    </span>
                  </span>
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
.map-btn--emphasis {
  background: #ecfdf5;
  color: #047857;
  box-shadow: 0 1px 3px rgba(16, 185, 129, 0.2), 0 0 0 1px rgba(16, 185, 129, 0.35);
}
.map-btn--emphasis:hover {
  background: #d1fae5;
}
.tenant-map-select :deep(.p-select) {
  font-size: 11px;
  border-radius: 8px;
  border: none;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.16), 0 0 0 1px rgba(0, 0, 0, 0.06);
  background: #fff;
}
.tenant-map-select :deep(.p-select-label) {
  padding: 6px 10px;
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
