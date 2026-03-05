<script setup lang="ts">
import BoundaryExplorer from '../components/BoundaryExplorer.vue';
import MapContainer from '../components/MapContainer.vue';
import LayerControl from '../components/LayerControl.vue';
</script>

<template>
  <div class="inspector-root">
    <BoundaryExplorer />
    <MapContainer>
      <LayerControl />
    </MapContainer>
  </div>
</template>

<style scoped>
.inspector-root {
  display: grid;
  grid-template-columns: 360px 1fr;
  height: calc(100vh - 48px);
  background: #020617;
  color: #e5e7eb;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI',
    sans-serif;
}

@media (max-width: 800px) {
  .inspector-root {
    grid-template-columns: 1fr;
    grid-template-rows: auto 1fr;
  }
}
</style>
