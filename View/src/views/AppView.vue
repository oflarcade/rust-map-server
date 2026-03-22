<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';
import { useTheme } from '../composables/useTheme';
import AppSidebar from '../components/AppSidebar.vue';
import CountryModeButton from '../components/CountryModeButton.vue';
import AddTenantWizard from '../components/AddTenantWizard.vue';
import Toast from 'primevue/toast';
import ConfirmDialog from 'primevue/confirmdialog';

const {
  mapContainer,
  reloadTenant,
  reloadTenantList,
  cleanup,
  resizeMap,
  addTenantWizardOpen,
  closeAddTenantWizard,
} = useTileInspector();
const { isDark, toggle: toggleTheme } = useTheme();

/** Default collapsed: sidebar is only the map icon until expanded. */
const sidebarCollapsed = ref(true);

function toggleSidebar() {
  sidebarCollapsed.value = !sidebarCollapsed.value;
  setTimeout(() => resizeMap(), 265);
}

async function onTenantCreated() {
  closeAddTenantWizard();
  await reloadTenantList();
}

onMounted(async () => {
  await reloadTenantList();
  await reloadTenant();
});

onUnmounted(() => cleanup());
</script>

<template>
  <Toast />
  <ConfirmDialog />

  <div
    class="h-screen overflow-hidden transition-[grid-template-columns] duration-300 ease-out"
    :style="{
      display: 'grid',
      gridTemplateColumns: sidebarCollapsed ? '56px 1fr' : '200px 1fr',
    }"
  >
    <AppSidebar :collapsed="sidebarCollapsed" @toggle-collapse="toggleSidebar" />

    <!-- Map area -->
    <div class="relative overflow-hidden min-w-0">
      <div ref="mapContainer" id="app-map" class="map-container"></div>
      <CountryModeButton />
      <button class="theme-btn" @click="toggleTheme" :title="isDark ? 'Light mode' : 'Dark mode'">
        {{ isDark ? '☀️' : '🌙' }}
      </button>
    </div>

    <AddTenantWizard
      v-if="addTenantWizardOpen"
      @close="closeAddTenantWizard"
      @created="onTenantCreated"
    />
  </div>
</template>

<style scoped>
.map-container {
  width: 100%;
  height: 100%;
}

.theme-btn {
  position: absolute;
  top: 100px;
  right: 10px;
  z-index: 10;
  width: 34px;
  height: 34px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #ffffff;
  border: none;
  border-radius: 8px;
  font-size: 15px;
  cursor: pointer;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.16), 0 0 0 1px rgba(0, 0, 0, 0.06);
  transition:
    background 0.12s,
    box-shadow 0.12s,
    transform 0.1s;
  user-select: none;
}
.theme-btn:hover {
  background: #f8fafc;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.18), 0 0 0 1px rgba(0, 0, 0, 0.07);
  transform: translateY(-0.5px);
}
</style>
