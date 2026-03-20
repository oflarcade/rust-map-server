<script setup lang="ts">
import { ref, computed } from 'vue';
import Button from 'primevue/button';
import GeoNodeFormDialog from './GeoNodeFormDialog.vue';
import { useGeoHierarchyEditor, type GeoNode } from '../composables/useGeoHierarchyEditor';
import type { HierarchyState } from '../types/boundary';

const {
  rawHierarchy,
  geoLevels,
  nodeTree,
  nodesLoading,
  deleteNode,
  enterSelectionMode,
  selectionMode,
} = useGeoHierarchyEditor();

// Dialog state
const showDialog   = ref(false);
const dialogParent = ref<GeoNode | null>(null);
const dialogState  = ref('');
const editNode     = ref<GeoNode | null>(null);

function openCreate(statePcode: string, parent: GeoNode | null) {
  dialogState.value  = statePcode;
  dialogParent.value = parent;
  editNode.value     = null;
  showDialog.value   = true;
}

function openEdit(node: GeoNode, statePcode: string) {
  dialogState.value  = statePcode;
  dialogParent.value = null;
  editNode.value     = node;
  showDialog.value   = true;
}

function closeDialog() {
  showDialog.value = false;
}

async function removeNode(node: GeoNode) {
  const msg = (node.constituent_pcodes?.length ?? 0) > 0
    ? `Delete "${node.name}"?\nThis will remove ${node.constituent_pcodes!.length} assigned LGAs from this node and recompute parent geometries.`
    : `Delete "${node.name}"?`;
  if (!confirm(msg)) return;
  await deleteNode(node.id).catch(() => {});
}

// Flat tree for rendering — avoids recursive component complexity
interface FlatNode {
  node: GeoNode;
  statePcode: string;
  depth: number;
}

function flattenTree(nodes: GeoNode[], statePcode: string, depth: number): FlatNode[] {
  const result: FlatNode[] = [];
  for (const n of nodes) {
    result.push({ node: n, statePcode, depth });
    if (n.children?.length) {
      result.push(...flattenTree(n.children, statePcode, depth + 1));
    }
  }
  return result;
}

const states = computed<HierarchyState[]>(() => rawHierarchy.value?.states ?? []);

interface StateGroup {
  pcode: string;
  name: string;
  flatNodes: FlatNode[];
}

const stateGroups = computed<StateGroup[]>(() => {
  return states.value.map(s => ({
    pcode: s.pcode,
    name:  s.name,
    flatNodes: flattenTree(nodeTree.value.get(s.pcode) ?? [], s.pcode, 1),
  }));
});
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Header -->
    <div class="px-2 py-1.5 bg-slate-50/80 border-b border-slate-200/90 flex-shrink-0">
      <div class="text-[10px] font-semibold text-slate-500 uppercase tracking-wider">Custom tree</div>
    </div>

    <div class="flex-1 overflow-y-auto">
      <div v-if="nodesLoading" class="p-3 text-xs text-slate-400">Loading…</div>
      <div v-else-if="geoLevels.length === 0" class="p-3 text-xs text-amber-600">
        Define hierarchy levels first (left panel above).
      </div>
      <template v-else>
        <div
          v-for="sg in stateGroups"
          :key="sg.pcode"
          class="border-b border-slate-100 last:border-0"
        >
          <!-- State heading -->
          <div class="flex items-center gap-2 px-3 py-2 bg-slate-50">
            <span class="font-semibold text-slate-700 text-sm">{{ sg.name }}</span>
            <span class="text-[10px] font-mono text-slate-400">{{ sg.pcode }}</span>
            <Button
              label="+ Group"
              size="small"
              severity="secondary"
              outlined
              class="ml-auto !text-[11px] !py-0.5 !px-2"
              :disabled="selectionMode === 'selecting'"
              @click="openCreate(sg.pcode, null)"
            />
          </div>

          <!-- Flat node rows -->
          <div
            v-for="{ node, statePcode, depth } in sg.flatNodes"
            :key="node.id"
            class="flex items-center gap-1.5 py-1 pr-3 hover:bg-slate-50 group text-xs"
            :style="{ paddingLeft: `${depth * 16 + 8}px` }"
          >
            <!-- Color dot -->
            <span
              class="w-2.5 h-2.5 rounded-full flex-shrink-0"
              :style="{ background: node.color ?? '#94a3b8' }"
            />

            <!-- Name -->
            <span class="font-medium text-slate-700 truncate">{{ node.name }}</span>

            <!-- Pcode -->
            <span class="text-[10px] font-mono text-slate-400 flex-shrink-0">{{ node.pcode }}</span>

            <!-- Level label -->
            <span
              v-if="node.level_label"
              class="text-[10px] text-slate-400 italic flex-shrink-0"
            >
              ({{ node.level_label }})
            </span>

            <!-- LGA count -->
            <span
              v-if="(node.constituent_pcodes?.length ?? 0) > 0"
              class="text-[10px] text-emerald-600 flex-shrink-0"
            >
              {{ node.constituent_pcodes!.length }} LGAs
            </span>

            <!-- Actions (show on hover) -->
            <div class="ml-auto flex items-center gap-1 opacity-0 group-hover:opacity-100 flex-shrink-0">
              <button
                class="text-[10px] text-indigo-500 hover:text-indigo-700 px-1 rounded"
                title="Add LGAs"
                :disabled="selectionMode === 'selecting'"
                @click="enterSelectionMode(node.id)"
              >
                +LGAs
              </button>
              <button
                class="text-[10px] text-slate-400 hover:text-slate-700 px-1 rounded"
                title="Add subgroup"
                :disabled="selectionMode === 'selecting'"
                @click="openCreate(statePcode, node)"
              >
                +Sub
              </button>
              <button
                class="text-[10px] text-slate-400 hover:text-slate-700 px-1"
                title="Edit"
                @click="openEdit(node, statePcode)"
              >
                <i class="pi pi-pencil text-[9px]" />
              </button>
              <button
                class="text-[10px] text-red-400 hover:text-red-600 px-1"
                title="Delete"
                @click="removeNode(node)"
              >
                <i class="pi pi-trash text-[9px]" />
              </button>
            </div>
          </div>

          <div
            v-if="sg.flatNodes.length === 0"
            class="px-5 py-2 text-xs text-slate-400 italic"
          >
            No groups yet. Click "+ Group" to start.
          </div>
        </div>
      </template>
    </div>
  </div>

  <!-- Create / edit dialog -->
  <GeoNodeFormDialog
    v-if="showDialog"
    :state-pcode="dialogState"
    :parent-node="dialogParent"
    :edit-node="editNode"
    @close="closeDialog"
  />
</template>
