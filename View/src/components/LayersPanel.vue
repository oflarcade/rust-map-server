<script setup lang="ts">
import Button from 'primevue/button';
import ToggleSwitch from 'primevue/toggleswitch';
import { useTileInspector } from '../composables/useTileInspector';
import { useMapLayers } from '../composables/useMapLayers';

const { layersPanelOpen } = useTileInspector();
const { baseControls, boundaryControls, toggleControl } = useMapLayers();
</script>

<template>
  <Transition name="panel-slide">
    <div
      v-if="layersPanelOpen"
      class="absolute top-0 right-0 z-30 bg-white border-l border-slate-200 shadow-lg h-full w-48 flex flex-col"
    >
      <div class="flex items-center px-3 pt-2 pb-1 border-b border-slate-100">
        <span class="text-sm font-bold text-slate-900 flex-1">Layers</span>
        <Button
          icon="pi pi-times"
          variant="text"
          size="small"
          class="self-end"
          @click="layersPanelOpen = false"
        />
      </div>

      <div class="flex flex-col overflow-y-auto flex-1 py-1">
        <div class="text-[10px] uppercase tracking-wider text-slate-500 px-3 mt-3 mb-1">Base</div>
        <div
          v-for="row in baseControls"
          :key="row.id"
          class="flex items-center justify-between px-3 py-1"
        >
          <label class="text-xs text-slate-700">{{ row.label }}</label>
          <ToggleSwitch v-model="row.visible" @update:modelValue="toggleControl(row)" />
        </div>

        <div class="text-[10px] uppercase tracking-wider text-slate-500 px-3 mt-3 mb-1">Boundaries</div>
        <div
          v-for="row in boundaryControls"
          :key="row.id"
          class="flex items-center justify-between px-3 py-1"
        >
          <label class="text-xs text-slate-700">{{ row.label }}</label>
          <ToggleSwitch v-model="row.visible" @update:modelValue="toggleControl(row)" />
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.panel-slide-enter-active,
.panel-slide-leave-active {
  transition: all 0.22s ease;
}
.panel-slide-enter-from,
.panel-slide-leave-to {
  opacity: 0;
  transform: translateY(-6px) scale(0.98);
}
</style>
