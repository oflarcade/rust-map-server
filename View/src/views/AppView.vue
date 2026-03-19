<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';
import { useTheme } from '../composables/useTheme';
import AppSidebar from '../components/AppSidebar.vue';
import CountryModeButton from '../components/CountryModeButton.vue';
import AddTenantWizard from '../components/AddTenantWizard.vue';

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
  <div class="app-root" :class="{ 'sidebar-collapsed': sidebarCollapsed }">
    <!-- Sidebar -->
    <AppSidebar
      :collapsed="sidebarCollapsed"
      @toggle-collapse="toggleSidebar"
      @open-wizard="showWizard = true"
    />

    <!-- Collapse toggle tab -->
    <div class="collapse-tab-col">
      <button class="collapse-tab" @click="toggleSidebar" :title="sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'">
        {{ sidebarCollapsed ? '›' : '‹' }}
      </button>
    </div>

    <!-- Map area -->
    <div class="map-area">
      <div ref="mapContainer" id="app-map" class="map-container"></div>
      <CountryModeButton />
      <!-- Dark/Light toggle — below MapLibre zoom controls -->
      <button class="theme-toggle-btn" :title="isDark ? 'Light mode' : 'Dark mode'" @click="toggleTheme">
        {{ isDark ? '☀️' : '🌙' }}
      </button>
    </div>

    <!-- Add Tenant Wizard -->
    <AddTenantWizard v-if="showWizard" @close="showWizard = false" @created="showWizard = false" />
  </div>
</template>

<style scoped>
.app-root {
  display: grid;
  grid-template-columns: 320px 16px 1fr;
  height: 100vh;
  overflow: hidden;
  transition: grid-template-columns 0.26s ease;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: #f1f5f9;
}

.app-root.sidebar-collapsed {
  grid-template-columns: 0px 16px 1fr;
}

/* Thin column for the collapse tab */
.collapse-tab-col {
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f8fafc;
  border-right: 1px solid #e2e8f0;
}

.collapse-tab {
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 6px;
  width: 14px;
  padding: 10px 0;
  cursor: pointer;
  font-size: 11px;
  color: #64748b;
  line-height: 1;
  box-shadow: 0 1px 4px rgba(0,0,0,0.06);
  transition: background 0.12s;
  writing-mode: vertical-rl;
}
.collapse-tab:hover { background: #f1f5f9; color: #0f172a; }

.map-area {
  position: relative;
  overflow: hidden;
}

.map-container {
  width: 100%;
  height: 100%;
}

.theme-toggle-btn {
  position: absolute;
  top: 100px;
  right: 10px;
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 7px;
  padding: 6px 10px;
  font-size: 15px;
  cursor: pointer;
  box-shadow: 0 1px 4px rgba(0,0,0,0.10);
  z-index: 10;
  transition: background 0.12s;
}
.theme-toggle-btn:hover { background: #f8fafc; }
</style>
