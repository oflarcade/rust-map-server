<script setup lang="ts">
import TenantModeHeader from './TenantModeHeader.vue';
import Button from 'primevue/button';

defineProps<{ collapsed: boolean }>();
const emit = defineEmits<{
  (e: 'toggle-collapse'): void;
  (e: 'open-wizard'): void;
}>();
</script>

<template>
  <aside class="bg-slate-50 border-r border-slate-200 flex flex-col overflow-hidden">
    <!-- Branded header bar — fixed, not scrollable -->
    <div class="px-4 py-3 bg-slate-900 flex items-center gap-2.5 flex-shrink-0">
      <i class="pi pi-globe text-indigo-400 text-base" />
      <div class="flex flex-col leading-tight min-w-0">
        <span class="font-semibold text-white text-sm tracking-tight">NewGlobe Geo</span>
        <span class="text-slate-500 text-[10px] font-medium tracking-wide">Hierarchies &amp; boundaries</span>
      </div>
    </div>

    <!-- Scrollable content -->
    <div class="flex-1 overflow-hidden flex flex-col">
      <div class="p-4 flex flex-col gap-2.5 h-full overflow-y-auto min-w-[300px] box-border">
        <TenantModeHeader />

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
