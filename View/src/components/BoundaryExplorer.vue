<script setup lang="ts">
import { ref, computed } from 'vue';
import { useRouter } from 'vue-router';
import { useTileInspector } from '../composables/useTileInspector';
import { useBoundarySearch } from '../composables/useBoundarySearch';
import { useMapInteraction } from '../composables/useMapInteraction';
import { TENANTS } from '../config/tenants';
import Select from 'primevue/select';
import InputText from 'primevue/inputtext';
import InputGroup from 'primevue/inputgroup';
import Button from 'primevue/button';
import Tree from 'primevue/tree';
import Tag from 'primevue/tag';
import type { TreeNode } from 'primevue/treenode';
import type { HierarchyState, HierarchyChild, HierarchyZone, HierarchyAdmNode } from '../types/boundary';

const router = useRouter();

const {
  selectedTenantId,
  currentTenant,
} = useTileInspector();

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
// Node selection handlers
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
  <aside class="bg-slate-50 text-slate-800 overflow-y-auto p-3.5 border-r border-slate-200 h-full max-[800px]:border-r-0 max-[800px]:border-b max-[800px]:border-slate-200 max-[800px]:max-h-[40vh]">
    <!-- Tenant selector -->
    <div class="pb-3 border-b border-slate-200 mb-3">
      <div class="text-[10px] uppercase tracking-widest text-slate-500 mb-1.5">Tenant</div>
      <Select
        v-model="selectedTenantId"
        :options="TENANTS"
        optionValue="id"
        :optionLabel="(t: typeof TENANTS[number]) => `${t.id} — ${t.name}`"
        class="w-full !text-sm"
      />
      <div class="mt-1 text-xs text-sky-700 font-semibold">{{ currentTenant.name }}</div>
      <Button
        label="Tenant Administrative Manager"
        icon="pi pi-arrow-right"
        iconPos="right"
        class="w-full mt-2 !text-xs"
        size="small"
        @click="router.push('/admin/zones')"
      />
      <Button
        :label="`View All ${currentTenant.countryCode} Tenants`"
        icon="pi pi-arrow-right"
        iconPos="right"
        variant="outlined"
        class="w-full mt-1.5 !text-xs"
        size="small"
        @click="router.push('/country/' + currentTenant.countryCode)"
      />
    </div>

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
        {{ hierarchy.states.reduce((n, s) => n + s.lgas.length, 0) }}
        LGA{{ hierarchy.states.reduce((n, s) => n + s.lgas.length, 0) !== 1 ? 's' : '' }}
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
          <span class="flex items-center gap-1 text-xs">
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
            <span class="text-slate-400 text-[10px]">({{ node.data.pcode }})</span>
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
