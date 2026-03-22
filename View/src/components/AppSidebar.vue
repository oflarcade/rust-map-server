<script setup lang="ts">
defineProps<{ collapsed: boolean }>();
const emit = defineEmits<{
  (e: 'toggle-collapse'): void;
}>();
</script>

<template>
  <!-- Collapsed: rail with map icon only (per spec) -->
  <aside
    v-if="collapsed"
    class="h-full w-full flex flex-col items-center pt-3 px-1 bg-slate-900 border-r border-slate-700 flex-shrink-0"
  >
    <button
      type="button"
      class="w-11 h-11 flex items-center justify-center rounded-xl bg-slate-800 text-indigo-400 hover:bg-slate-700 hover:text-indigo-300 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-400"
      title="Expand — New Globe"
      @click="emit('toggle-collapse')"
    >
      <i class="pi pi-map text-lg" />
    </button>
  </aside>

  <!-- Expanded: narrow strip — title + short app name only (no tree, no extra routes) -->
  <aside
    v-else
    class="h-full w-full max-w-[200px] flex flex-col bg-slate-900 border-r border-slate-700 flex-shrink-0"
  >
    <div class="px-2 py-2.5 flex items-start gap-2 flex-shrink-0 border-b border-slate-700">
      <button
        type="button"
        class="w-8 h-8 flex items-center justify-center rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 transition-colors flex-shrink-0 mt-0.5"
        title="Collapse to map icon"
        @click="emit('toggle-collapse')"
      >
        <i class="pi pi-angle-left text-sm" />
      </button>
      <i class="pi pi-map text-indigo-400 text-base flex-shrink-0 mt-1" />
      <div class="flex flex-col leading-tight min-w-0 flex-1">
        <span class="font-semibold text-white text-[13px] tracking-tight">New Globe</span>
        <span class="text-slate-500 text-[9px] font-medium leading-snug mt-0.5">
          Tenant Geo boundary Editor
        </span>
      </div>
    </div>
    <div class="flex-1 min-h-0 bg-slate-900" aria-hidden="true" />
  </aside>
</template>
