<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';
import { useTheme } from '../composables/useTheme';
import AppSidebar from '../components/AppSidebar.vue';
import CountryModeButton from '../components/CountryModeButton.vue';
import AddTenantWizard from '../components/AddTenantWizard.vue';
import Button from 'primevue/button';
import Toast from 'primevue/toast';
import ConfirmDialog from 'primevue/confirmdialog';

const { mapContainer, reloadTenant, reloadTenantList, cleanup, resizeMap } = useTileInspector();
const { isDark, toggle: toggleTheme } = useTheme();

const sidebarCollapsed = ref(false);
const showWizard = ref(false);

function toggleSidebar() {
  sidebarCollapsed.value = !sidebarCollapsed.value;
  setTimeout(() => resizeMap(), 265);
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
    class="h-screen overflow-hidden transition-[grid-template-columns] duration-300"
    :style="{
      display: 'grid',
      gridTemplateColumns: sidebarCollapsed ? '0px 16px 1fr' : '320px 16px 1fr',
    }"
  >
    <!-- Sidebar -->
    <AppSidebar
      :collapsed="sidebarCollapsed"
      @toggle-collapse="toggleSidebar"
      @open-wizard="showWizard = true"
    />

    <!-- Collapse toggle tab -->
    <div class="flex items-center justify-center bg-slate-50 border-r border-slate-200">
      <Button
        variant="text"
        size="small"
        :icon="sidebarCollapsed ? 'pi pi-chevron-right' : 'pi pi-chevron-left'"
        @click="toggleSidebar"
        :title="sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'"
        class="!p-1"
      />
    </div>

    <!-- Map area -->
    <div class="relative overflow-hidden">
      <div ref="mapContainer" id="app-map" class="map-container"></div>
      <CountryModeButton />
      <!-- Dark/Light toggle — below MapLibre zoom controls -->
      <button class="theme-btn" @click="toggleTheme" :title="isDark ? 'Light mode' : 'Dark mode'">
        {{ isDark ? '☀️' : '🌙' }}
      </button>
    </div>

    <!-- Add Tenant Wizard -->
    <AddTenantWizard v-if="showWizard" @close="showWizard = false" @created="showWizard = false" />
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
  box-shadow: 0 1px 3px rgba(0,0,0,0.16), 0 0 0 1px rgba(0,0,0,0.06);
  transition: background 0.12s, box-shadow 0.12s, transform 0.1s;
  user-select: none;
}
.theme-btn:hover {
  background: #f8fafc;
  box-shadow: 0 2px 8px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.07);
  transform: translateY(-0.5px);
}
</style>
