<script setup lang="ts">
import { computed } from 'vue';
import { useTileInspector } from '../composables/useTileInspector';

const { selectedTenantId, tenantList } = useTileInspector();

const groupedTenants = computed(() => {
  const groups: Record<string, typeof tenantList.value> = {};
  for (const t of tenantList.value) {
    if (!groups[t.countryCode]) groups[t.countryCode] = [];
    groups[t.countryCode].push(t);
  }
  return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
});
</script>

<template>
  <div class="tmh-root">
    <label class="selector-label">Tenant</label>
    <select v-model="selectedTenantId" class="tenant-select">
      <optgroup v-for="[cc, tenants] in groupedTenants" :key="cc" :label="cc">
        <option v-for="t in tenants" :key="t.id" :value="t.id">{{ t.name }}</option>
      </optgroup>
    </select>
  </div>
</template>

<style scoped>
.tmh-root { display: flex; flex-direction: column; gap: 3px; }
.selector-label { font-size: 10px; font-weight: 700; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; }
.tenant-select {
  width: 100%; border: 1px solid #e2e8f0; border-radius: 6px;
  padding: 6px 8px; font-size: 13px; color: #0f172a; background: #fff; cursor: pointer;
}
.tenant-select:focus { outline: none; border-color: #3b82f6; }
</style>
