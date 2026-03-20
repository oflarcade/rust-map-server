<script setup lang="ts">
import { useConfirm } from 'primevue/useconfirm';
import Button from 'primevue/button';
import type { Zone } from '../composables/useZoneManager';

const props = defineProps<{ zone: Zone; selected: boolean }>();
const emit = defineEmits<{
  (e: 'edit', zone: Zone): void;
  (e: 'delete', id: number): void;
}>();

const confirm = useConfirm();

function confirmDelete() {
  confirm.require({
    message: `Delete zone "${props.zone.zone_name}"?`,
    header: 'Confirm Delete',
    icon: 'pi pi-trash',
    acceptClass: 'p-button-danger',
    accept: () => emit('delete', props.zone.id),
  });
}
</script>

<template>
  <div
    class="flex items-center gap-2 px-2.5 py-1.5 rounded-md border cursor-pointer transition-colors duration-100 group"
    :class="selected
      ? 'border-blue-400 bg-blue-50 ring-1 ring-blue-300'
      : 'border-slate-200 bg-white hover:bg-slate-50'"
  >
    <span
      class="inline-block w-3 h-3 rounded-full flex-shrink-0"
      :style="{ background: zone.color ?? '#a78bfa' }"
    />
    <span class="flex-1 text-[13px] font-medium text-slate-900 min-w-0 truncate">
      {{ zone.zone_name }}
    </span>
    <span
      v-if="zone.zone_type_label"
      class="flex-shrink-0 text-[11px] text-slate-500 bg-slate-100 px-1.5 py-px rounded"
    >
      {{ zone.zone_type_label }}
    </span>
    <span
      class="flex gap-0.5 flex-shrink-0 opacity-0 transition-opacity duration-100 group-hover:opacity-100"
      :class="{ 'opacity-100': selected }"
    >
      <Button
        icon="pi pi-pencil"
        size="small"
        variant="text"
        aria-label="Edit"
        @click.stop="emit('edit', zone)"
      />
      <Button
        icon="pi pi-trash"
        size="small"
        variant="text"
        severity="danger"
        aria-label="Delete"
        @click.stop="confirmDelete()"
      />
    </span>
  </div>
</template>
