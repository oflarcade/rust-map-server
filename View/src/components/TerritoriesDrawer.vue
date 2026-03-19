<script setup lang="ts">
import { ref, onMounted, watch, computed } from 'vue';
import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { useTileInspector } from '../composables/useTileInspector';

const { selectedTenantId, loadHierarchy } = useTileInspector();
const BASE = normalizeBaseUrl(DEFAULT_PROXY_URL);

const open = ref(false);
const loading = ref(false);
const inScope = ref<any[]>([]);
const available = ref<any[]>([]);
const searchQ = ref('');
const adding = ref(false);
const deleting = ref<string | null>(null);

async function loadTerritories() {
  loading.value = true;
  try {
    const res = await fetch(`${BASE}/admin/territories`, {
      headers: { 'X-Tenant-ID': selectedTenantId.value },
    });
    if (res.ok) {
      const data = await res.json();
      inScope.value = data.in_scope ?? [];
      available.value = data.available ?? [];
    }
  } catch { /* ignore */ } finally {
    loading.value = false;
  }
}

async function addPcode(pcode: string) {
  adding.value = true;
  try {
    await fetch(`${BASE}/admin/territories`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': selectedTenantId.value },
      body: JSON.stringify({ pcodes: [pcode] }),
    });
    await loadTerritories();
    loadHierarchy();
  } catch { /* ignore */ } finally {
    adding.value = false;
  }
}

async function removePcode(pcode: string) {
  deleting.value = pcode;
  try {
    await fetch(`${BASE}/admin/territories/${pcode}`, {
      method: 'DELETE',
      headers: { 'X-Tenant-ID': selectedTenantId.value },
    });
    await loadTerritories();
    loadHierarchy();
  } catch { /* ignore */ } finally {
    deleting.value = null;
  }
}

const filteredAvailable = computed(() => {
  const q = searchQ.value.toLowerCase().trim();
  if (!q) return available.value;
  return available.value.filter((f) =>
    f.name?.toLowerCase().includes(q) || f.pcode?.toLowerCase().includes(q),
  );
});

// Group available by state name
const availableByState = computed(() => {
  const groups: Record<string, any[]> = {};
  for (const f of filteredAvailable.value) {
    const key = f.parent_name || f.parent_pcode || 'Other';
    if (!groups[key]) groups[key] = [];
    groups[key].push(f);
  }
  return Object.entries(groups).sort((a, b) => a[0].localeCompare(b[0]));
});

watch(open, (val) => { if (val && inScope.value.length === 0) loadTerritories(); });
watch(selectedTenantId, () => { inScope.value = []; available.value = []; if (open.value) loadTerritories(); });
</script>

<template>
  <div class="territories-drawer">
    <button class="drawer-toggle" @click="open = !open">
      <span class="toggle-icon">{{ open ? '▾' : '▸' }}</span>
      Territories
      <span v-if="inScope.length > 0" class="count-badge">{{ inScope.length }}</span>
    </button>

    <div v-if="open" class="drawer-body">
      <div v-if="loading" class="drawer-status">Loading…</div>

      <div v-else>
        <!-- In-scope list -->
        <div class="section-label">In scope ({{ inScope.length }})</div>
        <div class="in-scope-list">
          <div v-for="f in inScope" :key="f.pcode" class="scope-row">
            <span class="scope-name">{{ f.name }}</span>
            <span class="scope-pcode">{{ f.pcode }}</span>
            <button
              class="remove-btn"
              :disabled="deleting === f.pcode"
              @click="removePcode(f.pcode)"
            >✕</button>
          </div>
          <div v-if="inScope.length === 0" class="empty-text">None in scope</div>
        </div>

        <!-- Available -->
        <div class="section-label" style="margin-top:10px">Available to add</div>
        <input v-model="searchQ" placeholder="Search…" class="search-input" />
        <div class="available-list">
          <template v-for="[stateName, lgas] in availableByState" :key="stateName">
            <div class="state-header">{{ stateName }}</div>
            <div v-for="lga in lgas" :key="lga.pcode" class="available-row">
              <span class="scope-name">{{ lga.name }}</span>
              <span class="scope-pcode">{{ lga.pcode }}</span>
              <button class="add-btn" :disabled="adding" @click="addPcode(lga.pcode)">+</button>
            </div>
          </template>
          <div v-if="availableByState.length === 0" class="empty-text">No results</div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.territories-drawer { border-top: 1px solid #e2e8f0; margin-top: 6px; }

.drawer-toggle {
  width: 100%; text-align: left; background: none; border: none; cursor: pointer;
  display: flex; align-items: center; gap: 6px; padding: 8px 2px;
  font-size: 13px; font-weight: 600; color: #334155;
}
.drawer-toggle:hover { color: #0f172a; }
.toggle-icon { font-size: 10px; color: #64748b; }
.count-badge {
  margin-left: auto; background: #e0f2fe; color: #0284c7;
  font-size: 11px; padding: 1px 6px; border-radius: 10px; font-weight: 700;
}

.drawer-body { padding: 4px 0 8px; display: flex; flex-direction: column; gap: 4px; }
.drawer-status { font-size: 12px; color: #94a3b8; }

.section-label { font-size: 10px; font-weight: 700; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 4px; }

.in-scope-list {
  max-height: 120px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 6px; background: #fff;
}
.scope-row, .available-row {
  display: flex; align-items: center; gap: 6px;
  padding: 4px 8px; font-size: 12px; border-bottom: 1px solid #f1f5f9;
}
.scope-row:last-child, .available-row:last-child { border-bottom: none; }
.scope-name { flex: 1; color: #1e293b; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.scope-pcode { font-size: 10px; color: #94a3b8; flex-shrink: 0; }

.remove-btn {
  background: none; border: none; color: #94a3b8; cursor: pointer; font-size: 12px;
  padding: 1px 4px; border-radius: 3px; flex-shrink: 0;
}
.remove-btn:hover:not(:disabled) { background: #fee2e2; color: #dc2626; }
.remove-btn:disabled { opacity: 0.4; cursor: default; }

.search-input {
  width: 100%; box-sizing: border-box; border: 1px solid #e2e8f0; border-radius: 5px;
  padding: 5px 8px; font-size: 12px; margin-bottom: 4px;
}
.available-list {
  max-height: 160px; overflow-y: auto; border: 1px solid #e2e8f0; border-radius: 6px; background: #fff;
}
.state-header {
  padding: 4px 8px; font-size: 10px; font-weight: 700; color: #94a3b8;
  text-transform: uppercase; letter-spacing: 0.04em; background: #f8fafc;
  border-bottom: 1px solid #e2e8f0;
}
.add-btn {
  background: none; border: none; color: #3b82f6; cursor: pointer; font-size: 15px;
  font-weight: 700; padding: 0 4px; border-radius: 3px; flex-shrink: 0;
}
.add-btn:hover:not(:disabled) { background: #dbeafe; }
.add-btn:disabled { opacity: 0.4; cursor: default; }
.empty-text { padding: 8px; font-size: 12px; color: #94a3b8; text-align: center; }
</style>
