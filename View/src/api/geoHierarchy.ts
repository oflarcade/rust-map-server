import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';

function base(): string {
  return normalizeBaseUrl(DEFAULT_PROXY_URL);
}

function headers(tenantId: string, extra: Record<string, string> = {}): Record<string, string> {
  return { 'X-Tenant-ID': tenantId, ...extra };
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface GeoLevel {
  id: number;
  tenant_id: number;
  level_order: number;
  level_label: string;
  level_code: string;
}

export interface GeoNode {
  id: number;
  parent_id: number | null;
  state_pcode: string;
  level_id: number;
  pcode: string;
  name: string;
  color?: string;
  level_order?: number;
  level_label?: string;
  constituent_pcodes?: string[];
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
  created_at?: string;
  updated_at?: string;
  // client-side tree
  children?: GeoNode[];
}

export interface GeoLevelCreatePayload {
  level_order: number;
  level_label: string;
  level_code: string;
}

export interface GeoNodeCreatePayload {
  parent_id?: number | null;
  state_pcode: string;
  level_id: number;
  name: string;
  color?: string;
  constituent_pcodes?: string[];
}

export interface GeoNodeUpdatePayload {
  name?: string;
  color?: string;
  constituent_pcodes?: string[];
}

// ---------------------------------------------------------------------------
// Level API
// ---------------------------------------------------------------------------

/** Distinct `adm_features.level_label` for tenant's country (HDX-style names, adm_level ≥ 3). */
export async function fetchHdxLevelLabels(tenantId: string): Promise<string[]> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/level-labels`, {
    headers: headers(tenantId),
  });
  if (!res.ok) throw new Error(`fetchHdxLevelLabels ${res.status}`);
  const data = await res.json();
  return data.labels ?? [];
}

export async function fetchGeoLevels(tenantId: string): Promise<GeoLevel[]> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/levels`, {
    headers: headers(tenantId),
  });
  if (!res.ok) throw new Error(`fetchGeoLevels ${res.status}`);
  const data = await res.json();
  return data.levels ?? [];
}

export async function createGeoLevel(tenantId: string, payload: GeoLevelCreatePayload): Promise<GeoLevel> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/levels`, {
    method: 'POST',
    headers: headers(tenantId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error((err as any).error ?? `createGeoLevel ${res.status}`);
  }
  return res.json();
}

export async function updateGeoLevel(
  tenantId: string,
  id: number,
  payload: Partial<GeoLevelCreatePayload>,
): Promise<GeoLevel> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/levels/${id}`, {
    method: 'PUT',
    headers: headers(tenantId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`updateGeoLevel ${res.status}`);
  return res.json();
}

export async function deleteGeoLevel(tenantId: string, id: number): Promise<void> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/levels/${id}`, {
    method: 'DELETE',
    headers: headers(tenantId),
  });
  if (!res.ok) throw new Error(`deleteGeoLevel ${res.status}`);
}

// ---------------------------------------------------------------------------
// Node API
// ---------------------------------------------------------------------------

/** Lua encodes empty TEXT[] as {} (object) — normalize to undefined so `?? []` guards work. */
function normalizeNode(n: GeoNode): GeoNode {
  return Array.isArray(n.constituent_pcodes) ? n : { ...n, constituent_pcodes: undefined };
}

export async function fetchGeoNodes(tenantId: string): Promise<GeoNode[]> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/nodes`, {
    headers: headers(tenantId),
  });
  if (!res.ok) throw new Error(`fetchGeoNodes ${res.status}`);
  const data = await res.json();
  return (data.nodes ?? []).map(normalizeNode);
}

export async function createGeoNode(tenantId: string, payload: GeoNodeCreatePayload): Promise<GeoNode> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/nodes`, {
    method: 'POST',
    headers: headers(tenantId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error((err as any).error ?? `createGeoNode ${res.status}`);
  }
  return res.json().then(normalizeNode);
}

export async function updateGeoNode(
  tenantId: string,
  id: number,
  payload: GeoNodeUpdatePayload,
): Promise<GeoNode> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/nodes/${id}`, {
    method: 'PUT',
    headers: headers(tenantId, { 'Content-Type': 'application/json' }),
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error((err as any).error ?? `updateGeoNode ${res.status}`);
  }
  return res.json().then(normalizeNode);
}

export async function deleteGeoNode(tenantId: string, id: number): Promise<void> {
  const res = await fetch(`${base()}/admin/geo-hierarchy/nodes/${id}`, {
    method: 'DELETE',
    headers: headers(tenantId),
  });
  if (!res.ok) throw new Error(`deleteGeoNode ${res.status}`);
}

export async function fetchRawHierarchy(tenantId: string): Promise<any> {
  const res = await fetch(
    `${base()}/boundaries/hierarchy?raw=1&t=${tenantId}`,
    { headers: { 'X-Tenant-ID': tenantId }, cache: 'no-store' },
  );
  if (!res.ok) throw new Error(`fetchRawHierarchy ${res.status}`);
  const data = await res.json();
  // Lua encodes an empty table as {} (object) — normalise to array
  if (data && !Array.isArray(data.states)) data.states = [];
  return data;
}

// ---------------------------------------------------------------------------
// Client-side tree builder: flat node list -> nested tree by state_pcode
// ---------------------------------------------------------------------------
export function buildNodeTree(nodes: GeoNode[]): Map<string, GeoNode[]> {
  const byId = new Map<number, GeoNode>();
  for (const n of nodes) {
    byId.set(n.id, { ...n, children: [] });
  }

  const rootsByState = new Map<string, GeoNode[]>();

  for (const n of byId.values()) {
    if (n.parent_id != null) {
      const parent = byId.get(n.parent_id);
      if (parent) {
        parent.children = parent.children ?? [];
        parent.children.push(n);
      }
    } else {
      const list = rootsByState.get(n.state_pcode) ?? [];
      list.push(n);
      rootsByState.set(n.state_pcode, list);
    }
  }

  return rootsByState;
}

/**
 * Auto-generate a short level code from a label.
 * "Senatorial District" → "SD", "Federal Constituency" → "FC",
 * "Emirate" → "EM", "Ward" → "WA", "Zone" → "ZO"
 */
export function labelToCode(label: string): string {
  const words = label.trim().split(/\s+/);
  if (words.length === 1) return label.slice(0, 2).toUpperCase();
  return words.map(w => w[0]?.toUpperCase() ?? '').join('').slice(0, 4);
}

/** Collect all LGA pcodes assigned to any node under a given tenants flat list */
export function collectAssignedPcodes(nodes: GeoNode[]): Set<string> {
  const assigned = new Set<string>();
  for (const n of nodes) {
    for (const p of n.constituent_pcodes ?? []) assigned.add(p);
  }
  return assigned;
}
