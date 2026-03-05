<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from 'vue';
import { useTileInspector, type DataControlRow } from '../composables/useTileInspector';

const { baseControls, boundaryControls, toggleControl } = useTileInspector();

const expanded = ref(false);
const controlRoot = ref<HTMLDivElement | null>(null);

function onClickOutside(e: MouseEvent) {
  if (expanded.value && controlRoot.value && !controlRoot.value.contains(e.target as Node)) {
    expanded.value = false;
  }
}

onMounted(() => document.addEventListener('pointerdown', onClickOutside, true));
onBeforeUnmount(() => document.removeEventListener('pointerdown', onClickOutside, true));
</script>

<template>
  <div ref="controlRoot" class="layer-control">
    <button class="layer-toggle-btn" @click="expanded = !expanded">
      Layers
    </button>
    <div v-if="expanded" class="layer-panel">
      <div class="layer-section">
        <div class="layer-section-title">Base map data</div>
        <div class="layer-grid">
          <button
            v-for="row in baseControls"
            :key="row.id"
            class="layer-btn"
            :class="{ on: row.visible }"
            @click="toggleControl(row)"
          >
            {{ row.label }}
          </button>
        </div>
      </div>
      <div class="layer-section">
        <div class="layer-section-title">Boundary data</div>
        <div class="layer-grid">
          <button
            v-for="row in boundaryControls"
            :key="row.id"
            class="layer-btn"
            :class="{ on: row.visible }"
            @click="toggleControl(row)"
          >
            {{ row.label }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.layer-control {
  position: absolute;
  top: 50px;
  left: 10px;
  z-index: 10;
}

.layer-toggle-btn {
  background: rgba(0, 0, 0, 0.8);
  color: #e5e7eb;
  border: 1px solid #374151;
  border-radius: 6px;
  padding: 6px 12px;
  font-size: 12px;
  cursor: pointer;
}

.layer-toggle-btn:hover {
  background: rgba(0, 0, 0, 0.9);
  border-color: #4b5563;
}

.layer-panel {
  margin-top: 4px;
  background: #0f172a;
  border: 1px solid #334155;
  border-radius: 8px;
  padding: 12px;
  min-width: 240px;
}

.layer-section + .layer-section {
  margin-top: 10px;
  padding-top: 10px;
  border-top: 1px solid #1f2937;
}

.layer-section-title {
  font-size: 12px;
  color: #cbd5e1;
  font-weight: 600;
  margin-bottom: 6px;
}

.layer-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 6px;
}

.layer-btn {
  border: 1px solid #334155;
  border-radius: 6px;
  padding: 6px 8px;
  font-size: 11px;
  background: #020617;
  color: #e5e7eb;
  text-align: left;
  cursor: pointer;
}

.layer-btn.on {
  border-color: #0ea5e9;
  background: #082f49;
  color: #bae6fd;
}

.layer-btn:hover {
  border-color: #4b5563;
}
</style>
