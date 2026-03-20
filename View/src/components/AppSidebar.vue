<script setup lang="ts">
import TenantModeHeader from './TenantModeHeader.vue';
import ZoneSection from './ZoneSection.vue';
import Button from 'primevue/button';
import { useTileInspector } from '../composables/useTileInspector';

defineProps<{ collapsed: boolean }>();
const emit = defineEmits<{
  (e: 'toggle-collapse'): void;
  (e: 'open-wizard'): void;
}>();

const { tenantList } = useTileInspector();
</script>

<template>
  <aside class="bg-slate-50 border-r border-slate-200 flex flex-col overflow-hidden">
    <!-- Branded header bar — fixed, not scrollable -->
    <div class="px-4 py-3 bg-slate-900 flex items-center gap-2.5 flex-shrink-0">
      <i class="pi pi-map text-indigo-400 text-base" />
      <span class="font-semibold text-white text-sm tracking-tight">Map Inspector</span>
      <span class="ml-auto text-slate-500 text-xs font-medium tabular-nums">
        {{ tenantList.length }}
      </span>
    </div>

    <!-- Scrollable content -->
    <div class="flex-1 overflow-hidden flex flex-col">
      <div class="p-4 flex flex-col gap-2.5 h-full overflow-y-auto min-w-[300px] box-border">
        <TenantModeHeader />

        <hr class="border-slate-200 flex-shrink-0" />
        <ZoneSection />

        <div class="flex-1" />
        <hr class="border-slate-200 flex-shrink-0" />
        <Button
          label="+ Add New Tenant"
          severity="success"
          outlined
          class="w-full !text-sm"
          @click="emit('open-wizard')"
        />
      </div>
    </div>
  </aside>
</template>
