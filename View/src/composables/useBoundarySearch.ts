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

  const filteredHierarchy = computed<HierarchyData | null>(() => {
    const data = boundaryHierarchy.value;
    if (!data) return null;

    const q = boundarySearch.value.toLowerCase().trim();
    if (!q) return data;

    const matchedStates = data.states
      .map((state) => {
        const stateMatches =
          state.name.toLowerCase().includes(q) ||
          state.pcode.toLowerCase().includes(q);

        const matchingLgas = state.lgas.filter(
          (lga) =>
            lga.name.toLowerCase().includes(q) ||
            lga.pcode.toLowerCase().includes(q),
        );

        if (stateMatches) return { ...state };
        if (matchingLgas.length > 0) return { ...state, lgas: matchingLgas };
        return null;
      })
      .filter((s): s is HierarchyState => s !== null);

    return { ...data, states: matchedStates };
  });

  const filteredStateNames = computed(() => {
    const data = boundaryHierarchy.value;
    if (!data) return [];
    const q = boundarySearch.value.toLowerCase().trim();
    if (!q) {
      return data.states.map((s) => s.name).sort((a, b) => a.localeCompare(b));
    }
    return data.states
      .filter((s) => s.name.toLowerCase().includes(q) || s.pcode.toLowerCase().includes(q))
      .map((s) => s.name)
      .sort((a, b) => a.localeCompare(b));
  });

  const filteredLGANames = computed(() => {
    const data = boundaryHierarchy.value;
    if (!data) return [];
    const q = boundarySearch.value.toLowerCase().trim();
    const allLgas = data.states.flatMap((s) => s.lgas);
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
