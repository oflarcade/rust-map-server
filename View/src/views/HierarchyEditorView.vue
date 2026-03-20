<script setup lang="ts">
import { computed } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';
import LevelConfigPanel from '../components/LevelConfigPanel.vue';
import RawBoundaryPanel from '../components/RawBoundaryPanel.vue';
import HierarchyBuilderPanel from '../components/HierarchyBuilderPanel.vue';
import { TENANTS } from '../config/tenants';

const { selectedTenantId } = useTileInspector();

const currentTenantName = computed(() => {
  const t = TENANTS.find(t => t.id === selectedTenantId.value);
  return t?.name ?? `Tenant ${selectedTenantId.value}`;
});
</script>

<template>
  <div class="h-screen flex flex-col overflow-hidden bg-slate-50">
    <!-- Top bar -->
    <div class="flex-shrink-0 h-14 bg-slate-900 flex items-center gap-4 px-5 border-b border-slate-700">
      <RouterLink
        to="/"
        class="text-slate-400 hover:text-white text-sm flex items-center gap-1.5"
      >
        <i class="pi pi-arrow-left text-xs" />
        Back
      </RouterLink>
      <i class="pi pi-globe text-indigo-400" />
      <span class="font-semibold text-white text-sm tracking-tight">NewGlobe Geo</span>
      <span class="text-slate-500 text-[10px] uppercase tracking-wider">Editor</span>
      <span class="text-slate-400 text-xs">—</span>
      <span class="text-slate-300 text-sm">{{ currentTenantName }}</span>

      <!-- Tenant selector -->
      <select
        v-model="selectedTenantId"
        class="ml-auto bg-slate-800 text-slate-200 border border-slate-600 rounded px-2 py-1 text-xs"
      >
        <option v-for="t in TENANTS" :key="t.id" :value="t.id">
          {{ t.name }}
        </option>
      </select>
    </div>

    <!-- Level config row -->
    <div class="flex-shrink-0 px-4 py-2 border-b border-slate-200 bg-white">
      <LevelConfigPanel />
    </div>

    <!-- Two-panel layout -->
    <div class="flex-1 overflow-hidden flex min-h-0">
      <!-- Left panel: Raw boundaries (40%) -->
      <div class="w-2/5 border-r border-slate-200 bg-white flex flex-col overflow-hidden">
        <RawBoundaryPanel />
      </div>

      <!-- Right panel: Custom hierarchy (60%) -->
      <div class="flex-1 bg-white flex flex-col overflow-hidden">
        <HierarchyBuilderPanel />
      </div>
    </div>
  </div>
</template>
