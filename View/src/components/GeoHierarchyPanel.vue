<script setup lang="ts">
import { computed, ref } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';
import { useBoundarySearch } from '../composables/useBoundarySearch';
import { useMapInteraction } from '../composables/useMapInteraction';
import InputText from 'primevue/inputtext';
import Button from 'primevue/button';
import Tree from 'primevue/tree';
import Tag from 'primevue/tag';
import type { TreeNode } from 'primevue/treenode';
import type { HierarchyState, HierarchyChild, HierarchyZone, HierarchyAdmNode, HierarchyLGA } from '../types/boundary';

const { hierarchyPanelOpen } = useTileInspector();
const { filteredHierarchy, boundarySearch, boundaryHierarchy } = useBoundarySearch();
const { flyToHierarchyItem, highlightBoundary, highlight } = useMapInteraction();

const selectionKeys = ref<Record<string, boolean>>({});

// ---------------------------------------------------------------------------
// Tree node builders (same pattern as BoundaryExplorer.vue)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Node selection handler
// ---------------------------------------------------------------------------

function onNodeSelect(node: TreeNode) {
  const d = node.data as { type: string; pcode: string; name: string };
  if (d.type === 'state') {
    const state = boundaryHierarchy.value?.states.find((s) => s.pcode === d.pcode);
    if (state) flyToHierarchyItem(state);
    highlightBoundary({ pcode: d.pcode, level: 'state', name: d.name });
  } else if (d.type === 'zone') {
    highlightBoundary({ pcode: d.pcode, level: 'zone' });
  } else {
    // lga or adm leaf
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
</script>

<template>
  <Transition name="panel-slide">
    <div
      v-if="hierarchyPanelOpen"
      class="absolute top-2.5 left-[130px] w-[320px] bg-white border border-slate-200 rounded-xl shadow-[0_4px_20px_rgba(0,0,0,0.12)] z-10 overflow-y-auto overflow-x-hidden"
      style="max-height: calc(100vh - 80px)"
    >
      <!-- Header — sticky so it stays visible when tree scrolls -->
      <div class="flex items-center px-3 pt-2.5 pb-1.5 border-b border-slate-100 sticky top-0 bg-white z-10">
        <span class="flex-1 text-[13px] font-bold text-slate-900">Geo Hierarchy</span>
        <Button icon="pi pi-times" variant="text" size="small" @click="hierarchyPanelOpen = false" />
      </div>

      <!-- Search — sticky below header -->
      <div class="px-3 py-1.5 sticky top-[44px] bg-white z-10 border-b border-slate-100">
        <InputText v-model="boundarySearch" placeholder="Search boundaries…" class="w-full !text-sm" />
      </div>

      <!-- Tree body — natural flow, no overflow (outer panel scrolls) -->
      <div class="px-1 pb-2">
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
</template>

<style scoped>
/* Slide animation */
.panel-slide-enter-active,
.panel-slide-leave-active {
  transition: all 0.22s ease;
}
.panel-slide-enter-from,
.panel-slide-leave-to {
  opacity: 0;
  transform: translateY(-8px) scale(0.98);
}

:deep(mark) {
  background: #fef9c3;
  color: inherit;
  border-radius: 2px;
}
</style>
