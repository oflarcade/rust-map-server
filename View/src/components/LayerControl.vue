<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from 'vue';
import Button from 'primevue/button';
import ToggleSwitch from 'primevue/toggleswitch';
import { useMapLayers } from '../composables/useMapLayers';

const { baseControls, boundaryControls, toggleControl } = useMapLayers();

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
  <div ref="controlRoot" class="absolute top-[50px] left-2.5 z-10">
    <Button
      :icon="expanded ? 'pi pi-times' : 'pi pi-sliders-h'"
      variant="text"
      rounded
      class="bg-white/90 shadow"
      @click="expanded = !expanded"
    />

    <div
      v-if="expanded"
      class="mt-1 bg-white rounded-lg shadow-lg border border-slate-200 p-3 min-w-[160px]"
    >
      <div class="mb-2.5">
        <div class="text-[10px] uppercase tracking-wider text-slate-500 mb-1">Base map data</div>
        <div class="flex flex-col gap-1.5">
          <div
            v-for="row in baseControls"
            :key="row.id"
            class="flex items-center justify-between"
          >
            <label class="text-xs text-slate-700">{{ row.label }}</label>
            <ToggleSwitch v-model="row.visible" @update:modelValue="toggleControl(row)" />
          </div>
        </div>
      </div>

      <div class="pt-2.5 border-t border-slate-100">
        <div class="text-[10px] uppercase tracking-wider text-slate-500 mb-1">Boundary data</div>
        <div class="flex flex-col gap-1.5">
          <div
            v-for="row in boundaryControls"
            :key="row.id"
            class="flex items-center justify-between"
          >
            <label class="text-xs text-slate-700">{{ row.label }}</label>
            <ToggleSwitch v-model="row.visible" @update:modelValue="toggleControl(row)" />
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
