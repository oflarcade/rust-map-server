import { computed, ref } from 'vue';
import { useQuery } from '@tanstack/vue-query';
import { fetchHierarchy } from '../api/boundaries';
import { useTileInspector } from './useTileInspector';
import type { HierarchyData, HierarchyState } from '../types/boundary';

// Module-level shared state
const boundarySearch = ref('');

export function useBoundarySearch() {
  const { selectedTenantId } = useTileInspector();

  const { data: boundaryHierarchy, isLoading: hierarchyLoading } = useQuery({
    queryKey: computed(() => ['tenant', selectedTenantId.value, 'hierarchy']),
    queryFn: () => fetchHierarchy(selectedTenantId.value),
  });

  function matchesInTree(children: any[], q: string): boolean {
    for (const child of children ?? []) {
      const name  = (child.name  ?? child.zone_name  ?? '').toLowerCase();
      const pcode = (child.pcode ?? child.zone_pcode ?? '').toLowerCase();
      if (name.includes(q) || pcode.includes(q)) return true;
      if (matchesInTree(child.children ?? [], q)) return true;
    }
    return false;
  }

  // If any state has custom geo_hierarchy_nodes children, only show states
  // that have children — states without custom hierarchy are excluded from the panel.
  const activeStates = computed<HierarchyState[]>(() => {
    const data = boundaryHierarchy.value;
    if (!data) return [];
    const hasCustomHierarchy = data.states.some(s => (s.children ?? []).length > 0);
    return hasCustomHierarchy
      ? data.states.filter(s => (s.children ?? []).length > 0)
      : data.states;
  });

  const filteredHierarchy = computed<HierarchyData | null>(() => {
    const data = boundaryHierarchy.value;
    if (!data) return null;

    const q = boundarySearch.value.toLowerCase().trim();
    if (!q) return { ...data, states: activeStates.value };

    const matchedStates = activeStates.value
      .map((state) => {
        const stateMatches =
          state.name.toLowerCase().includes(q) ||
          state.pcode.toLowerCase().includes(q);
        if (stateMatches) return { ...state };

        const matchingLgas = state.lgas.filter(
          (lga) =>
            lga.name.toLowerCase().includes(q) ||
            lga.pcode.toLowerCase().includes(q),
        );
        if (matchingLgas.length > 0) return { ...state, lgas: matchingLgas };

        // Search geo_hierarchy_nodes children tree (Senatorial Districts, Sectors, etc.)
        if (matchesInTree(state.children, q)) return { ...state };

        return null;
      })
      .filter((s): s is HierarchyState => s !== null);

    return { ...data, states: matchedStates };
  });

  const filteredStateNames = computed(() => {
    if (!boundaryHierarchy.value) return [];
    const q = boundarySearch.value.toLowerCase().trim();
    if (!q) {
      return activeStates.value.map((s) => s.name).sort((a, b) => a.localeCompare(b));
    }
    return activeStates.value
      .filter((s) => s.name.toLowerCase().includes(q) || s.pcode.toLowerCase().includes(q))
      .map((s) => s.name)
      .sort((a, b) => a.localeCompare(b));
  });

  const filteredLGANames = computed(() => {
    if (!boundaryHierarchy.value) return [];
    const q = boundarySearch.value.toLowerCase().trim();
    const allLgas = activeStates.value.flatMap((s) => s.lgas);
    if (!q) {
      return allLgas.map((l) => l.name).sort((a, b) => a.localeCompare(b));
    }
    return allLgas
      .filter((l) => l.name.toLowerCase().includes(q) || l.pcode.toLowerCase().includes(q))
      .map((l) => l.name)
      .sort((a, b) => a.localeCompare(b));
  });

  return {
    boundarySearch,
    boundaryHierarchy,
    hierarchyLoading,
    filteredHierarchy,
    filteredStateNames,
    filteredLGANames,
  };
}
