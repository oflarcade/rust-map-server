<script setup lang="ts">
import type { Zone } from '../composables/useZoneManager';

const props = defineProps<{ zone: Zone; selected: boolean }>();
const emit = defineEmits<{
  (e: 'edit', zone: Zone): void;
  (e: 'delete', id: number): void;
}>();
</script>

<template>
  <div class="zone-row" :class="{ selected }">
    <span class="swatch" :style="{ background: zone.color ?? '#a78bfa' }"></span>
    <span class="zone-name">{{ zone.zone_name }}</span>
    <span v-if="zone.zone_type_label" class="zone-type">{{ zone.zone_type_label }}</span>
    <span class="zone-actions">
      <button class="action-btn" title="Edit" @click.stop="emit('edit', zone)">✎</button>
      <button class="action-btn danger" title="Delete" @click.stop="emit('delete', zone.id)">✕</button>
    </span>
  </div>
</template>

<style scoped>
.zone-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 10px;
  border-radius: 6px;
  border: 1px solid #e2e8f0;
  background: #fff;
  cursor: pointer;
  transition: background 0.12s;
}
.zone-row:hover { background: #f8fafc; }
.zone-row.selected { border-color: #3b82f6; background: #eff6ff; }

.swatch {
  width: 10px; height: 10px; border-radius: 3px; flex-shrink: 0;
}
.zone-name { flex: 1; font-size: 13px; font-weight: 500; color: #1e293b; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.zone-type { font-size: 11px; color: #64748b; flex-shrink: 0; background: #f1f5f9; padding: 1px 5px; border-radius: 4px; }

.zone-actions { display: flex; gap: 2px; flex-shrink: 0; opacity: 0; transition: opacity 0.12s; }
.zone-row:hover .zone-actions,
.zone-row.selected .zone-actions { opacity: 1; }

.action-btn {
  background: none; border: none; cursor: pointer;
  font-size: 13px; padding: 2px 4px; border-radius: 4px;
  color: #64748b;
}
.action-btn:hover { background: #e2e8f0; color: #0f172a; }
.action-btn.danger:hover { background: #fee2e2; color: #dc2626; }
</style>
