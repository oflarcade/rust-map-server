<script setup lang="ts">
import { RouterView } from 'vue-router';
import { useTileInspector } from './composables/useTileInspector';
import { TENANTS } from './config/tenants';

const { selectedTenantId, currentTenant } = useTileInspector();
</script>

<template>
  <div class="app-root">
    <header class="app-header">
      <h1 class="app-title">Tile Inspector</h1>
      <div class="tenant-select-wrap">
        <select v-model="selectedTenantId" class="tenant-select">
          <option
            v-for="t in TENANTS"
            :key="t.id"
            :value="t.id"
          >
            {{ t.id }} - {{ t.name }}
          </option>
        </select>
      </div>
      <span class="tenant-label">{{ currentTenant.name }}</span>
    </header>
    <main class="app-main">
      <RouterView />
    </main>
  </div>
</template>

<style scoped>
.app-root {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

.app-header {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 0.5rem 1rem;
  background: #1f2933;
  color: #f9fafb;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
}

.app-title {
  font-size: 1rem;
  margin: 0;
  color: #67e8f9;
}

.tenant-select-wrap {
  margin-left: auto;
}

.tenant-select {
  background: #0f172a;
  color: #e5e7eb;
  border: 1px solid #334155;
  border-radius: 6px;
  padding: 4px 8px;
  font-size: 13px;
}

.tenant-label {
  font-size: 12px;
  color: #9ca3af;
}

.app-main {
  flex: 1;
  min-height: 0;
}
</style>
