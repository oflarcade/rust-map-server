<script setup lang="ts">
import { onMounted, onBeforeUnmount } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';

const { mapContainer, currentZoom, reloadTenant, cleanup } = useTileInspector();

onMounted(() => reloadTenant());
onBeforeUnmount(() => cleanup());
</script>

<template>
  <div class="map-wrap">
    <div class="zoom-badge">z{{ currentZoom.toFixed(1) }}</div>
    <div ref="mapContainer" class="map" />
    <slot />
  </div>
</template>

<style scoped>
.map-wrap {
  position: relative;
  width: 100%;
  height: 100%;
}

.map {
  width: 100%;
  height: 100%;
}

.zoom-badge {
  position: absolute;
  top: 10px;
  left: 10px;
  z-index: 2;
  background: rgba(0, 0, 0, 0.8);
  color: #fff;
  font-family: monospace;
  font-size: 12px;
  padding: 6px 10px;
  border-radius: 6px;
  border: 1px solid #374151;
}
</style>
