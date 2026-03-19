<script setup lang="ts">
import TenantModeHeader from './TenantModeHeader.vue';
import ZoneSection from './ZoneSection.vue';

defineProps<{ collapsed: boolean }>();
const emit = defineEmits<{
  (e: 'toggle-collapse'): void;
  (e: 'open-wizard'): void;
}>();
</script>

<template>
  <aside class="sidebar" :class="{ collapsed }">
    <div class="sidebar-inner">
      <TenantModeHeader />

      <div class="section-divider"></div>
      <ZoneSection />

      <div class="sidebar-spacer"></div>
      <div class="section-divider"></div>
      <button class="add-tenant-btn" @click="emit('open-wizard')">
        + Add New Tenant
      </button>
    </div>
  </aside>
</template>

<style scoped>
.sidebar {
  background: #f8fafc;
  border-right: 1px solid #e2e8f0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.sidebar.collapsed { overflow: hidden; }

.sidebar-inner {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 10px;
  height: 100%;
  overflow-y: auto;
  min-width: 300px;
  box-sizing: border-box;
}

.section-divider { height: 1px; background: #e2e8f0; flex-shrink: 0; }
.sidebar-spacer { flex: 1; }

.add-tenant-btn {
  width: 100%; background: #f0fdf4; color: #15803d;
  border: 1px solid #bbf7d0; border-radius: 8px;
  padding: 9px 16px; font-size: 13px; font-weight: 600; cursor: pointer;
  transition: background 0.12s;
}
.add-tenant-btn:hover { background: #dcfce7; }
</style>
