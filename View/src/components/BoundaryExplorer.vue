<script setup lang="ts">
import { ref, computed } from 'vue';
import { useBoundarySearch } from '../composables/useBoundarySearch';
import { useMapInteraction } from '../composables/useMapInteraction';
import InputText from 'primevue/inputtext';
import InputGroup from 'primevue/inputgroup';
import Tree from 'primevue/tree';
import Tag from 'primevue/tag';
import type { TreeNode } from 'primevue/treenode';
import type { HierarchyState, HierarchyChild, HierarchyZone, HierarchyAdmNode } from '../types/boundary';

const {
  boundarySearch,
  boundaryHierarchy,
  filteredHierarchy,
} = useBoundarySearch();

const {
  highlightBoundary,
  flyToHierarchyItem,
  highlight,
} = useMapInteraction();

const hierarchy = filteredHierarchy;

// ---------------------------------------------------------------------------
// Selection state for PrimeVue Tree
// ---------------------------------------------------------------------------

const selectionKeys = ref<Record<string, boolean>>({});

// ---------------------------------------------------------------------------
// Tree node builders
// ---------------------------------------------------------------------------

function buildChildNode(child: HierarchyChild): TreeNode {
  if ('zone_pcode' in child) {
    // HierarchyZone
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
    // HierarchyAdmNode
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

// ---------------------------------------------------------------------------
// Node selection handlers
// ---------------------------------------------------------------------------

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

function onNodeUnselect(_node: TreeNode) {
  highlightBoundary(null);
}

// ---------------------------------------------------------------------------
// Highlight helper (delegates to util via useMapInteraction)
// ---------------------------------------------------------------------------

function highlightPcode(pcode: string): string {
  return highlight(pcode, boundarySearch.value);
}
</script>

<template>
  <aside
    class="boundary-explorer-aside bg-slate-50 text-slate-800 overflow-y-auto p-3 border-r border-slate-200 h-full min-h-0 max-[800px]:border-r-0 max-[800px]:border-b max-[800px]:border-slate-200 max-[800px]:max-h-[40vh]"
  >
    <!-- Search -->
    <section class="mt-3 pt-2.5 border-t border-slate-200">
      <InputGroup>
        <InputText
          v-model="boundarySearch"
          placeholder="Search by name or pcode…"
          class="w-full !text-sm"
        />
        <Button
          v-if="boundarySearch"
          icon="pi pi-times"
          variant="outlined"
          size="small"
          @click="boundarySearch = ''"
        />
      </InputGroup>
      <p v-if="boundarySearch && hierarchy" class="text-[11px] text-slate-400 mt-1.5">
        {{ hierarchy.states.length }} state{{ hierarchy.states.length !== 1 ? 's' : '' }},
        {{ hierarchy.states.reduce((n, s) => n + s.adm2s.length, 0) }}
        area{{ hierarchy.states.reduce((n, s) => n + s.adm2s.length, 0) !== 1 ? 's' : '' }}
      </p>
    </section>

    <!-- Hierarchy Tree -->
    <section v-if="hierarchy" class="mt-3 pt-2.5 border-t border-slate-200">
      <div class="text-xs font-semibold text-slate-700 mb-1.5">Boundary Hierarchy</div>
      <div class="flex justify-between items-center py-1 border-b border-slate-200 mb-1">
        <span
          class="font-semibold text-sky-700 text-xs"
          v-html="highlight(hierarchy.name, boundarySearch) + ' (' + highlightPcode(hierarchy.pcode) + ')'"
        ></span>
        <span class="text-[10px] text-slate-400">
          {{ hierarchy.state_count ?? hierarchy.states.length }} states
        </span>
      </div>
      <Tree
        :value="treeNodes"
        selectionMode="single"
        v-model:selectionKeys="selectionKeys"
        @node-select="onNodeSelect"
        @node-unselect="onNodeUnselect"
        class="w-full !border-0 !p-0 !text-xs"
        :pt="{ root: { class: 'border border-slate-200 rounded-md p-2' } }"
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
    </section>
  </aside>
</template>

<style scoped>
:deep(mark) {
  background: #bfdbfe;
  color: #1e3a5f;
  border-radius: 2px;
  padding: 0 1px;
}
</style>
