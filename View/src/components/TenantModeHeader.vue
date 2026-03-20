<script setup lang="ts">
import { computed } from 'vue';
import Select from 'primevue/select';
import { useTileInspector } from '../composables/useTileInspector';
import type { TenantConfig } from '../types/tenant';

const { selectedTenantId, tenantList, currentTenant } = useTileInspector();

const CC_COLORS: Record<string, string> = {
  NG: '#16a34a', KE: '#2563eb', UG: '#7c3aed', RW: '#db2777', LR: '#ea580c', IN: '#f59e0b', CF: '#64748b',
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
</script>

<template>
  <div class="flex flex-col gap-1">
    <label class="text-[10px] font-bold text-slate-400 uppercase tracking-wide">Tenant</label>

    <Select
      v-model="selectedTenantId"
      :options="groupedTenants"
      optionGroupLabel="label"
      optionGroupChildren="items"
      optionValue="id"
      :optionLabel="(t: TenantConfig) => t.name"
      class="w-full text-sm"
    >
      <!-- Selected value display -->
      <template #value="{ value }">
        <template v-if="value">
          <div class="flex items-center gap-2">
            <span
              class="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-bold text-white leading-none"
              :style="{ backgroundColor: ccColor(currentTenant.countryCode) }"
            >{{ currentTenant.countryCode }}</span>
            <span class="text-sm text-slate-800 truncate">{{ currentTenant.name }}</span>
          </div>
        </template>
        <template v-else>
          <span class="text-slate-400 text-sm">Select tenant…</span>
        </template>
      </template>

      <!-- Country group headers -->
      <template #optiongroup="{ option: group }">
        <div class="flex items-center gap-2 px-1 py-0.5">
          <span
            class="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-bold text-white leading-none"
            :style="{ backgroundColor: ccColor(group.label) }"
          >{{ group.label }}</span>
          <span class="text-[10px] font-semibold text-slate-400 uppercase tracking-wider">{{ group.items.length }} tenant{{ group.items.length !== 1 ? 's' : '' }}</span>
        </div>
      </template>

      <!-- Option rows -->
      <template #option="{ option }">
        <div class="flex items-center gap-2">
          <span class="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-medium text-slate-500 bg-slate-100 leading-none tabular-nums min-w-[22px]">
            {{ option.id }}
          </span>
          <span class="text-sm text-slate-700 truncate">{{ option.name }}</span>
        </div>
      </template>
    </Select>

    <!-- Selected tenant info card -->
    <div
      v-if="currentTenant"
      class="bg-blue-50 border border-blue-100 rounded-lg px-3 py-2 mt-1 flex items-center gap-2"
    >
      <span
        class="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-bold text-white leading-none flex-shrink-0"
        :style="{ backgroundColor: ccColor(currentTenant.countryCode) }"
      >{{ currentTenant.countryCode }}</span>
      <span class="text-sm font-medium text-slate-800 truncate flex-1">{{ currentTenant.name }}</span>
      <span class="text-xs text-slate-400 font-medium tabular-nums flex-shrink-0">#{{ currentTenant.id }}</span>
    </div>
  </div>
</template>
