<script setup lang="ts">
import { onMounted, onBeforeUnmount } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';

const { mapContainer, currentZoom, reloadTenant, cleanup } = useTileInspector();

onMounted(() => reloadTenant());
onBeforeUnmount(() => cleanup());
</script>

<template>
  <div class="relative w-full h-full">
    <div
      class="absolute bottom-2 right-14 bg-white/80 backdrop-blur-sm text-xs px-2 py-0.5 rounded shadow text-slate-600 z-10"
    >
      z{{ currentZoom.toFixed(1) }}
    </div>
    <div ref="mapContainer" class="w-full h-full" />
    <slot />
  </div>
</template>
