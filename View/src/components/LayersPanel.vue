<script setup lang="ts">
import { useTileInspector } from '../composables/useTileInspector';

const { layersPanelOpen, baseControls, boundaryControls, toggleControl } = useTileInspector();
</script>

<template>
  <Transition name="panel-slide">
    <div v-if="layersPanelOpen" class="layers-panel">
      <div class="panel-header">
        <span class="panel-title">Layers</span>
        <button class="close-btn" @click="layersPanelOpen = false">✕</button>
      </div>
      <div class="panel-body">
        <div class="group-label">Base</div>
        <label v-for="row in baseControls" :key="row.id" class="layer-row">
          <input type="checkbox" :checked="row.visible" @change="toggleControl(row)" />
          <span>{{ row.label }}</span>
        </label>

        <div class="group-label" style="margin-top:8px">Boundaries</div>
        <label v-for="row in boundaryControls" :key="row.id" class="layer-row">
          <input type="checkbox" :checked="row.visible" @change="toggleControl(row)" />
          <span>{{ row.label }}</span>
        </label>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.layers-panel {
  position: absolute;
  top: 78px; /* below Country + Geo Hierarchy rows */
  left: 130px;
  width: 220px;
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 10px;
  box-shadow: 0 4px 20px rgba(0,0,0,0.12);
  z-index: 10;
  overflow: hidden;
}

.panel-header {
  display: flex; align-items: center;
  padding: 10px 12px 6px;
  border-bottom: 1px solid #f1f5f9;
}
.panel-title { font-size: 13px; font-weight: 700; color: #0f172a; flex: 1; }
.close-btn {
  background: none; border: none; cursor: pointer; color: #94a3b8;
  font-size: 12px; padding: 2px 4px; border-radius: 3px;
}
.close-btn:hover { background: #f1f5f9; color: #475569; }

.panel-body { padding: 8px 12px 12px; display: flex; flex-direction: column; gap: 4px; }

.group-label {
  font-size: 10px; font-weight: 700; color: #94a3b8;
  text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 2px;
}
.layer-row {
  display: flex; align-items: center; gap: 8px;
  font-size: 12px; color: #334155; cursor: pointer; padding: 2px 0;
}
.layer-row:hover { color: #0f172a; }

.panel-slide-enter-active, .panel-slide-leave-active { transition: all 0.22s ease; }
.panel-slide-enter-from, .panel-slide-leave-to { opacity: 0; transform: translateY(-6px) scale(0.98); }
</style>
