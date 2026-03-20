import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';

export interface ScopeItem {
  pcode: string;
  name: string;
  adm_level: number;
  children_count: number;
}

export interface AvailableItem {
  pcode: string;
  name: string;
  adm_level: number;
  parent_pcode: string;
  parent_name: string;
}

export interface TerritoriesResponse {
  in_scope: ScopeItem[];
  available: AvailableItem[];
}

function proxyBase(): string {
  return normalizeBaseUrl(DEFAULT_PROXY_URL);
}

export async function fetchTerritories(tenantId: string): Promise<TerritoriesResponse> {
  const res = await fetch(`${proxyBase()}/admin/territories`, {
    headers: { 'X-Tenant-ID': tenantId },
  });
  if (!res.ok) throw new Error(`territories ${res.status}`);
  return res.json() as Promise<TerritoriesResponse>;
}

export async function addTerritories(
  tenantId: string,
  pcodes: string[],
): Promise<{ added: number }> {
  const res = await fetch(`${proxyBase()}/admin/territories`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': tenantId },
    body: JSON.stringify({ pcodes }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error ?? res.statusText);
  return data as { added: number };
}

export async function removeTerritory(tenantId: string, pcode: string): Promise<void> {
  const res = await fetch(
    `${proxyBase()}/admin/territories/${encodeURIComponent(pcode)}`,
    { method: 'DELETE', headers: { 'X-Tenant-ID': tenantId } },
  );
  const data = await res.json();
  if (!res.ok) throw new Error(data.error ?? res.statusText);
}
