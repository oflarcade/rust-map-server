<script setup lang="ts">
import { useTileInspector } from '../composables/useTileInspector';
import RawBoundaryPanel from './RawBoundaryPanel.vue';
import HierarchyBuilderPanel from './HierarchyBuilderPanel.vue';

const { hierarchyEditorOpen } = useTileInspector();
</script>

<template>
  <div class="editor-shell">
    <div class="editor-shell__header">
      <div class="editor-shell__title">
        <i class="pi pi-pen-to-square text-indigo-500 text-[11px]" />
        <span>Hierarchy Editor</span>
      </div>
      <button
        type="button"
        class="editor-shell__close"
        title="Close"
        @click="hierarchyEditorOpen = false"
      >
        <i class="pi pi-times text-[10px]" />
      </button>
    </div>

    <div class="editor-shell__split">
      <div class="editor-shell__col editor-shell__col--raw">
        <RawBoundaryPanel />
      </div>
      <div class="editor-shell__col editor-shell__col--tree">
        <HierarchyBuilderPanel />
      </div>
    </div>
  </div>
</template>

<style scoped>
.editor-shell {
  width: min(1040px, calc(100vw - 20px));
  max-height: min(900px, calc(100vh - 56px));
  height: calc(100vh - 80px);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.96);
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  border-radius: 12px;
  box-shadow:
    0 4px 24px rgba(0, 0, 0, 0.12),
    0 0 0 1px rgba(15, 23, 42, 0.07);
}

.editor-shell__header {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 12px;
  border-bottom: 1px solid rgba(226, 232, 240, 0.95);
  background: linear-gradient(180deg, rgba(248, 250, 252, 0.98) 0%, rgba(241, 245, 249, 0.4) 100%);
}

.editor-shell__title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  font-weight: 600;
  color: #1e293b;
  letter-spacing: 0.015em;
}

.editor-shell__close {
  width: 26px;
  height: 26px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: none;
  border-radius: 7px;
  background: #e2e8f0;
  color: #64748b;
  cursor: pointer;
  transition:
    background 0.12s ease,
    color 0.12s ease,
    transform 0.1s ease;
}
.editor-shell__close:hover {
  background: #cbd5e1;
  color: #0f172a;
}
.editor-shell__close:active {
  transform: scale(0.96);
}

.editor-shell__split {
  flex: 1;
  min-height: 280px;
  display: flex;
  overflow: hidden;
}

.editor-shell__col {
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.editor-shell__col--raw {
  width: 40%;
  flex: 1 1 42%;
  min-width: 0;
  min-height: 200px;
  border-right: 1px solid rgba(226, 232, 240, 0.95);
  background: rgba(255, 255, 255, 0.65);
}

.editor-shell__col--tree {
  flex: 1 1 58%;
  min-width: 0;
  background: rgba(255, 255, 255, 0.85);
}
</style>
