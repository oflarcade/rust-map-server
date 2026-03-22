<script setup lang="ts">
import { ref, computed, watch, nextTick, reactive } from 'vue';
import Button from 'primevue/button';
import GeoNodeFormDialog from './GeoNodeFormDialog.vue';
import { useGeoHierarchyEditor, type GeoNode } from '../composables/useGeoHierarchyEditor';
import { useTileInspector } from '../composables/useTileInspector';
import type { HierarchyState } from '../types/boundary';

const COUNTRY_NAMES: Record<string, string> = {
  NG: 'Nigeria', KE: 'Kenya', UG: 'Uganda', RW: 'Rwanda',
  LR: 'Liberia', CF: 'Central African Republic', IN: 'India',
};

const {
  rawHierarchy,
  geoNodes,
  nodeTree,
  nodesLoading,
  deleteNode,
  updateNode,
  enterSelectionMode,
  enterSelectionModeForArea,
  selectionMode,
  targetNodeId,
  focusedStatePcode,
  activeStatePcodes,
  showCountryRoot,
  isMultiStateTenant,
  toggleCountryRoot,
  adm1Label,
  adm2Label,
  adm2Short,
} = useGeoHierarchyEditor();

/**
 * Maps node id → adm level.
 * Rule: root node (parent_id=null) = adm2; each child = parent's adm + 1.
 * Purely based on actual parent_id chain — no level_order, no tree depth.
 */
const nodeAdmMap = computed<Map<number, number>>(() => {
  const byId = new Map<number, GeoNode>();
  for (const n of geoNodes.value) byId.set(n.id, n);

  const adm = new Map<number, number>();
  function resolve(id: number): number {
    if (adm.has(id)) return adm.get(id)!;
    const n = byId.get(id);
    if (!n || n.parent_id == null) { adm.set(id, 2); return 2; }
    const v = resolve(n.parent_id) + 1;
    adm.set(id, v);
    return v;
  }
  for (const n of geoNodes.value) resolve(n.id);
  return adm;
});

/** Leaf unit nodes (one-unit-per-node pattern) — don't expand constituent children. */
function isLeafNode(node: GeoNode): boolean {
  return node.level_label?.toLowerCase() === adm2Label.value.toLowerCase();
}

const { currentTenant } = useTileInspector();
const countryName = computed(() =>
  COUNTRY_NAMES[currentTenant.value.countryCode?.toUpperCase() ?? ''] ?? currentTenant.value.name,
);

watch(focusedStatePcode, (pcode) => {
  if (!pcode) return;
  nextTick(() => {
    document.getElementById(`hb-state-${pcode}`)?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  });
});

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
    ? `Delete "${node.name}"?\nThis will remove ${node.constituent_pcodes!.length} assigned ${adm2Label.value}s from this node and recompute parent geometries.`
    : `Delete "${node.name}"?`;
  if (!confirm(msg)) return;
  await deleteNode(node.id).catch(() => {});
}

// adm2 name lookup — pcode → name from raw hierarchy
const adm2NameMap = computed<Map<string, string>>(() => {
  const m = new Map<string, string>();
  for (const s of rawHierarchy.value?.states ?? []) {
    for (const l of (s as any).lgas ?? []) m.set(l.pcode, l.name);
  }
  return m;
});

// ---------------------------------------------------------------------------
// adm3+ child-area support (e.g. Rwanda: District → Sector)
// ---------------------------------------------------------------------------

/** Map: adm2 pcode → adm3+ children from raw hierarchy */
const parentChildMap = computed<Map<string, any[]>>(() => {
  const m = new Map<string, any[]>();
  for (const s of rawHierarchy.value?.states ?? []) {
    for (const lga of (s as any).lgas ?? []) {
      if (lga.children?.length) m.set(lga.pcode, lga.children);
    }
  }
  return m;
});

/** All adm3+ child pcodes — distinguishes adm2 from adm3+ in constituent_pcodes */
const childPcodeSet = computed<Set<string>>(() => {
  const s = new Set<string>();
  for (const children of parentChildMap.value.values()) {
    for (const c of children) s.add(c.pcode);
  }
  return s;
});

/** Label for adm3+ unit ("Sector", "Ward", …) — null if tenant has no adm3 */
const childAreaLabel = computed<string | null>(() => {
  for (const children of parentChildMap.value.values()) {
    if (children.length) return (children[0].level_label as string) || null;
  }
  return null;
});

/** Returns adm3+ child areas (in constituent_pcodes) for a leaf adm2 node. */
function getChildAreasForNode(node: GeoNode): any[] {
  const explicitChildren = (node.constituent_pcodes ?? []).filter(p => childPcodeSet.value.has(p));
  if (explicitChildren.length === 0) return [];
  const all: any[] = [];
  for (const children of parentChildMap.value.values()) all.push(...children);
  const byPcode = new Map(all.map(c => [c.pcode, c]));
  return explicitChildren.map(p => byPcode.get(p)).filter(Boolean);
}

async function removeChildAreaFromNode(node: GeoNode, childPcode: string, childName: string) {
  if (!confirm(`Remove "${childName}" from "${node.name}"?`)) return;
  const updated = (node.constituent_pcodes ?? []).filter(p => p !== childPcode);
  await updateNode(node.id, { constituent_pcodes: updated });
}

// Flat tree for rendering
interface FlatNode {
  node: GeoNode;
  statePcode: string;
  depth: number;
  type: 'node' | 'constituent' | 'child-area';
  constituentPcode?: string;
  constituentName?: string;
  childPcode?: string;
  childName?: string;
  childLabel?: string;
}

function flattenTree(nodes: GeoNode[], statePcode: string, depth: number): FlatNode[] {
  const result: FlatNode[] = [];
  for (const n of nodes) {
    result.push({ node: n, statePcode, depth, type: 'node' });
    if (n.children?.length) {
      // Child GeoNodes exist — recurse into them
      result.push(...flattenTree(n.children, statePcode, depth + 1));
    } else if (isLeafNode(n)) {
      // Leaf adm2 node (individual unit): show adm3+ child areas from raw hierarchy
      for (const c of getChildAreasForNode(n)) {
        result.push({
          node: n, statePcode, depth: depth + 1, type: 'child-area',
          childPcode: c.pcode, childName: c.name, childLabel: c.level_label,
        });
      }
    } else if ((n.constituent_pcodes?.length ?? 0) > 0) {
      // Grouping node: show constituent adm2 units inline (skip adm3+ child pcodes)
      for (const pcode of n.constituent_pcodes!) {
        if (childPcodeSet.value.has(pcode)) continue; // already shown as GeoNode children
        result.push({
          node: n, statePcode, depth: depth + 1, type: 'constituent',
          constituentPcode: pcode, constituentName: adm2NameMap.value.get(pcode) ?? pcode,
        });
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Multi-select delete
// ---------------------------------------------------------------------------
const deleteSelectMode  = ref(false);
const selectedForDelete = reactive(new Set<number>());

function toggleDeleteMode() {
  deleteSelectMode.value = !deleteSelectMode.value;
  selectedForDelete.clear();
}

function toggleNodeForDelete(nodeId: number) {
  if (selectedForDelete.has(nodeId)) selectedForDelete.delete(nodeId);
  else selectedForDelete.add(nodeId);
}

async function deleteSelectedNodes() {
  const count = selectedForDelete.size;
  if (count === 0) return;
  // Check if any parent nodes are also selected — children will be cascade-deleted
  const toDelete = [...selectedForDelete].filter(id => {
    const node = geoNodes.value.find(n => n.id === id);
    return !node?.parent_id || !selectedForDelete.has(node.parent_id);
  });
  const childrenMsg = toDelete.length < count
    ? `\n(${count - toDelete.length} child node${count - toDelete.length !== 1 ? 's' : ''} will be deleted via cascade)`
    : '';
  if (!confirm(`Delete ${toDelete.length} node${toDelete.length !== 1 ? 's' : ''} and all their children?${childrenMsg}`)) return;
  for (const id of toDelete) {
    await deleteNode(id).catch(() => {});
  }
  selectedForDelete.clear();
  deleteSelectMode.value = false;
}

// ---------------------------------------------------------------------------
// Collapse state
// ---------------------------------------------------------------------------
const collapsedStates = reactive(new Set<string>());
const collapsedNodes  = reactive(new Set<number>());

// Auto-collapse any node that has children the first time we see it with children.
// Uses a seen-set so manual expand (toggleNode) isn't overridden on re-render.
const autoCollapseSeen = new Set<number>();
watch(geoNodes, (nodes) => {
  const parentIds = new Set(nodes.map(n => n.parent_id).filter((id): id is number => id != null));
  for (const id of parentIds) {
    if (!autoCollapseSeen.has(id)) {
      autoCollapseSeen.add(id);
      collapsedNodes.add(id);
    }
  }
}, { immediate: true });

function toggleState(pcode: string) {
  if (collapsedStates.has(pcode)) collapsedStates.delete(pcode);
  else collapsedStates.add(pcode);
}

function toggleNode(nodeId: number) {
  if (collapsedNodes.has(nodeId)) collapsedNodes.delete(nodeId);
  else collapsedNodes.add(nodeId);
}

/** True if a flat-node entry should be visible given current collapse state. */
function isFlatNodeVisible(flatNode: FlatNode): boolean {
  // constituent / child-area rows: hidden when their owning node is collapsed
  if (flatNode.type === 'constituent' || flatNode.type === 'child-area') {
    return !collapsedNodes.has(flatNode.node.id);
  }
  // node rows: hidden when any ancestor node in the chain is collapsed
  // Build byId lazily from the same geoNodes ref
  let pid = flatNode.node.parent_id;
  if (pid == null) return true; // root nodes always visible
  const byId = new Map(geoNodes.value.map(n => [n.id, n]));
  while (pid != null) {
    if (collapsedNodes.has(pid)) return false;
    pid = byId.get(pid)?.parent_id ?? null;
  }
  return true;
}

/** True if a node row has collapsible children in the flat list. */
function nodeHasChildren(nodeId: number, flatNodes: FlatNode[]): boolean {
  return flatNodes.some(f =>
    (f.type === 'constituent' || f.type === 'child-area')
      ? f.node.id === nodeId
      : f.type === 'node' && f.node.parent_id === nodeId,
  );
}

const states = computed<HierarchyState[]>(() => rawHierarchy.value?.states ?? []);

interface StateGroup {
  pcode: string;
  name: string;
  flatNodes: FlatNode[];
}

const stateGroups = computed<StateGroup[]>(() => {
  return states.value
    .filter(s => activeStatePcodes.value.has(s.pcode))
    .map(s => ({
      pcode: s.pcode,
      name:  s.name,
      flatNodes: flattenTree(nodeTree.value.get(s.pcode) ?? [], s.pcode, 1),
    }));
});
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Header -->
    <div class="px-2 py-1.5 bg-slate-50/80 border-b border-slate-200/90 flex-shrink-0 flex items-center gap-1.5">
      <div class="text-[10px] font-semibold text-slate-500 uppercase tracking-wider flex-1 min-w-0">Custom tree</div>

      <!-- Delete selected button (only when nodes are checked) -->
      <button
        v-if="deleteSelectMode && selectedForDelete.size > 0"
        type="button"
        class="flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded border bg-red-50 border-red-300 text-red-600 hover:bg-red-100 shrink-0"
        :title="`Delete ${selectedForDelete.size} selected node(s)`"
        @click="deleteSelectedNodes"
      >
        <i class="pi pi-trash text-[9px]" />
        Delete ({{ selectedForDelete.size }})
      </button>

      <!-- Toggle multi-select delete mode -->
      <button
        type="button"
        class="flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded border transition-colors shrink-0"
        :class="deleteSelectMode
          ? 'bg-red-50 border-red-200 text-red-600'
          : 'bg-slate-100 border-slate-200 text-slate-500 hover:border-slate-300'"
        :title="deleteSelectMode ? 'Cancel selection' : 'Select nodes to delete'"
        @click="toggleDeleteMode"
      >
        <i :class="deleteSelectMode ? 'pi pi-times' : 'pi pi-check-square'" class="text-[9px]" />
        {{ deleteSelectMode ? 'Cancel' : 'Select' }}
      </button>

      <button
        v-if="!isMultiStateTenant"
        type="button"
        class="flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded border transition-colors shrink-0"
        :class="showCountryRoot
          ? 'bg-indigo-50 border-indigo-200 text-indigo-600'
          : 'bg-slate-100 border-slate-200 text-slate-500 hover:border-slate-300'"
        :title="showCountryRoot ? 'Switch to state-root view' : 'Switch to country-root view'"
        @click="toggleCountryRoot"
      >
        <i :class="showCountryRoot ? 'pi pi-globe' : 'pi pi-map-marker'" class="text-[9px]" />
        {{ showCountryRoot ? 'Country' : 'State' }}
      </button>
    </div>

    <div class="flex-1 overflow-y-auto">
      <div v-if="nodesLoading" class="p-3 text-xs text-slate-400">Loading…</div>
      <template v-else>
        <!-- Country root row -->
        <div
          v-if="showCountryRoot"
          class="flex items-center gap-2 px-3 py-2 bg-slate-100/80 border-b border-slate-200/80 sticky top-0 z-10"
        >
          <i class="pi pi-globe text-[10px] text-slate-500 flex-shrink-0" />
          <span class="font-bold text-slate-700 text-xs tracking-wide">{{ countryName }}</span>
          <span class="text-[9px] font-mono text-slate-400 flex-shrink-0">adm0</span>
        </div>

        <div v-if="stateGroups.length === 0" class="px-6 py-5 text-xs text-slate-400 italic leading-relaxed">
          Click a <strong class="text-slate-600">state name</strong> in the left panel to start building its hierarchy here.
        </div>

        <div
          v-for="sg in stateGroups"
          :id="'hb-state-' + sg.pcode"
          :key="sg.pcode"
          class="border-b border-slate-100 last:border-0 scroll-mt-2 rounded-sm transition-shadow"
          :class="focusedStatePcode === sg.pcode ? 'ring-2 ring-indigo-400/80 ring-inset bg-indigo-50/30' : ''"
        >
          <!-- State heading -->
          <div
            class="flex items-center gap-2 pr-3 py-2 bg-slate-50/80"
            :class="showCountryRoot ? 'pl-6' : 'pl-3'"
          >
            <!-- Collapse chevron -->
            <button
              class="flex-shrink-0 flex items-center justify-center w-4 h-4 rounded hover:bg-slate-200 transition-colors"
              :title="collapsedStates.has(sg.pcode) ? 'Expand' : 'Collapse'"
              @click="toggleState(sg.pcode)"
            >
              <i
                class="pi text-[9px] text-slate-400 transition-transform duration-150"
                :class="collapsedStates.has(sg.pcode) ? 'pi-chevron-right' : 'pi-chevron-down'"
              />
            </button>
            <i v-if="showCountryRoot" class="pi pi-map-marker text-[9px] text-slate-400 flex-shrink-0" />
            <span class="font-semibold text-slate-700 text-sm">{{ sg.name }}</span>
            <span class="text-[10px] font-mono text-slate-400">{{ sg.pcode }}</span>
            <span class="text-[9px] text-slate-400 italic flex-shrink-0">{{ adm1Label }}</span>
            <button
              v-if="!deleteSelectMode"
              class="ml-auto text-[10px] text-indigo-500 hover:text-indigo-700 px-1.5 py-0.5 rounded border border-indigo-200 hover:border-indigo-400 shrink-0"
              :title="`Add ${adm2Label}s directly under this ${adm1Label}`"
              :disabled="selectionMode === 'selecting'"
              @click="enterSelectionModeForArea(sg.pcode)"
            >
              +{{ adm2Short }}s
            </button>
            <Button
              v-if="!deleteSelectMode"
              label="+ Level"
              size="small"
              severity="secondary"
              outlined
              class="!text-[11px] !py-0.5 !px-2 shrink-0"
              :disabled="selectionMode === 'selecting'"
              @click="openCreate(sg.pcode, null)"
            />
          </div>

          <!-- Flat node + LGA rows -->
          <template v-if="!collapsedStates.has(sg.pcode)">
          <template v-for="flatNode in sg.flatNodes" :key="flatNode.type === 'child-area' ? `child-${flatNode.node.id}-${flatNode.childPcode}` : flatNode.type === 'constituent' ? `const-${flatNode.constituentPcode}` : `node-${flatNode.node.id}`">
            <!-- Custom node row -->
            <div
              v-if="flatNode.type === 'node' && isFlatNodeVisible(flatNode)"
              class="flex items-center gap-1.5 py-1 pr-3 group text-xs transition-colors cursor-default"
              :class="deleteSelectMode && selectedForDelete.has(flatNode.node.id)
                ? 'bg-red-50 border-l-2 border-red-300'
                : selectionMode === 'selecting' && flatNode.node.id === targetNodeId
                  ? 'bg-amber-50 border-l-2 border-amber-400 ring-1 ring-inset ring-amber-200'
                  : 'hover:bg-slate-50'"
              @click="deleteSelectMode ? toggleNodeForDelete(flatNode.node.id) : undefined"
              :style="{ paddingLeft: `${flatNode.depth * 16 + (showCountryRoot ? 24 : 8)}px` }"
            >
              <!-- Delete-select checkbox -->
              <input
                v-if="deleteSelectMode"
                type="checkbox"
                :checked="selectedForDelete.has(flatNode.node.id)"
                class="w-3 h-3 accent-red-500 flex-shrink-0"
                @change.stop="toggleNodeForDelete(flatNode.node.id)"
              />
              <!-- Node collapse chevron (hidden in delete select mode to save space) -->
              <button
                v-else-if="nodeHasChildren(flatNode.node.id, sg.flatNodes)"
                class="flex-shrink-0 flex items-center justify-center w-3.5 h-3.5 rounded hover:bg-slate-200 transition-colors"
                :title="collapsedNodes.has(flatNode.node.id) ? 'Expand' : 'Collapse'"
                @click.stop="toggleNode(flatNode.node.id)"
              >
                <i
                  class="pi text-[8px] text-slate-400 transition-transform duration-150"
                  :class="collapsedNodes.has(flatNode.node.id) ? 'pi-chevron-right' : 'pi-chevron-down'"
                />
              </button>
              <!-- Spacer when no chevron, so color dot stays aligned -->
              <span v-else class="w-3.5 flex-shrink-0" />
              <span
                class="w-2.5 h-2.5 rounded-full flex-shrink-0"
                :style="{ background: flatNode.node.color ?? '#94a3b8' }"
              />
              <span
                v-if="selectionMode === 'selecting' && flatNode.node.id === targetNodeId"
                class="text-[9px] font-semibold text-amber-600 bg-amber-100 border border-amber-300 rounded px-1 py-px flex-shrink-0 tracking-wide"
              >→ adding</span>
              <span class="font-medium text-slate-700 truncate">{{ flatNode.node.name }}</span>
              <span class="text-[10px] font-mono text-slate-400 flex-shrink-0">{{
                flatNode.node.constituent_pcodes?.length === 1
                  ? flatNode.node.constituent_pcodes[0]
                  : flatNode.node.pcode
              }}</span>
              <span v-if="flatNode.node.level_label" class="text-[10px] text-slate-400 italic flex-shrink-0">
                ({{ flatNode.node.level_label }})
              </span>
              <span class="text-[9px] font-mono text-slate-300 flex-shrink-0">adm{{ nodeAdmMap.get(flatNode.node.id) ?? 2 }}</span>
              <div v-if="!deleteSelectMode" class="ml-auto flex items-center gap-1 opacity-0 group-hover:opacity-100 flex-shrink-0">
                <!-- For grouping nodes: add sub-areas or sub-levels -->
                <button
                  v-if="!isLeafNode(flatNode.node)"
                  class="text-[10px] text-indigo-500 hover:text-indigo-700 px-1 rounded"
                  :title="`Add ${adm2Label}s`"
                  :disabled="selectionMode === 'selecting'"
                  @click="enterSelectionMode(flatNode.node.id)"
                >
                  +{{ adm2Short }}s
                </button>
                <button
                  v-if="!isLeafNode(flatNode.node)"
                  class="text-[10px] text-slate-400 hover:text-slate-700 px-1 rounded"
                  title="Add sub-level"
                  :disabled="selectionMode === 'selecting'"
                  @click="openCreate(flatNode.statePcode, flatNode.node)"
                >
                  +Level
                </button>
                <!-- For individual adm2 leaf nodes: add adm3+ child areas -->
                <button
                  v-if="isLeafNode(flatNode.node) && childAreaLabel"
                  class="text-[10px] text-indigo-500 hover:text-indigo-700 px-1 rounded"
                  :title="`Add ${childAreaLabel}s`"
                  :disabled="selectionMode === 'selecting'"
                  @click="enterSelectionMode(flatNode.node.id)"
                >
                  +{{ childAreaLabel }}s
                </button>
                <button
                  class="text-[10px] text-slate-400 hover:text-slate-700 px-1"
                  title="Edit"
                  @click="openEdit(flatNode.node, flatNode.statePcode)"
                >
                  <i class="pi pi-pencil text-[9px]" />
                </button>
                <button
                  class="text-[10px] text-red-400 hover:text-red-600 px-1"
                  title="Delete"
                  @click="removeNode(flatNode.node)"
                >
                  <i class="pi pi-trash text-[9px]" />
                </button>
              </div>
            </div>

            <!-- Child-area row (adm3+ under a leaf node, e.g. Sector under District) -->
            <div
              v-else-if="flatNode.type === 'child-area' && isFlatNodeVisible(flatNode)"
              class="flex items-center gap-1.5 pr-3 py-0.5 hover:bg-slate-50 group/child text-[11px]"
              :style="{ paddingLeft: `${flatNode.depth * 16 + (showCountryRoot ? 24 : 8)}px` }"
            >
              <span class="w-1 h-1 rounded-full bg-slate-300 flex-shrink-0" />
              <span class="text-slate-600 truncate flex-1">{{ flatNode.childName }}</span>
              <span class="text-[10px] font-mono text-slate-400 flex-shrink-0">{{ flatNode.childPcode }}</span>
              <span v-if="flatNode.childLabel" class="text-[9px] text-slate-400 italic flex-shrink-0">{{ flatNode.childLabel }}</span>
              <button
                class="opacity-0 group-hover/child:opacity-100 text-[10px] text-red-400 hover:text-red-600 px-1 ml-1 flex-shrink-0"
                title="Remove from node"
                @click="removeChildAreaFromNode(flatNode.node, flatNode.childPcode!, flatNode.childName!)"
              >
                <i class="pi pi-times text-[8px]" />
              </button>
            </div>

            <!-- Constituent row (adm2 unit grouped inside a parent node) -->
            <div
              v-else-if="flatNode.type === 'constituent' && isFlatNodeVisible(flatNode)"
              class="flex items-center gap-2 pr-3 py-0.5"
              :style="{ paddingLeft: `${flatNode.depth * 16 + (showCountryRoot ? 24 : 8)}px` }"
            >
              <span class="w-1.5 h-1.5 rounded-full bg-slate-300 flex-shrink-0" />
              <span class="text-xs text-slate-600 truncate">{{ flatNode.constituentName }}</span>
              <span class="text-[10px] font-mono text-slate-400 flex-shrink-0">{{ flatNode.constituentPcode }}</span>
            </div>
          </template>
          </template><!-- end v-if collapsedStates -->

          <div
            v-if="sg.flatNodes.length === 0 && !collapsedStates.has(sg.pcode)"
            class="pr-3 py-2 text-xs text-slate-400 italic"
            :style="{ paddingLeft: showCountryRoot ? '2.75rem' : '2rem' }"
          >
            Click <strong class="text-slate-500">+ Level</strong> to add the first custom level.
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
