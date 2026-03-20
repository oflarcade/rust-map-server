import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import type { HierarchyData } from '../types/boundary';
import type { BoundaryFeatureCollection } from '../types/geojson';

function proxyBase(): string {
  return normalizeBaseUrl(DEFAULT_PROXY_URL);
}

export async function fetchHierarchy(tenantId: string): Promise<HierarchyData> {
  const res = await fetch(
    `${proxyBase()}/boundaries/hierarchy?t=${tenantId}&_=${Date.now()}`,
    { headers: { 'X-Tenant-ID': tenantId } },
  );
  if (!res.ok) throw new Error(`hierarchy ${res.status}`);
  return res.json() as Promise<HierarchyData>;
}

export async function fetchBoundaryGeoJSON(tenantId: string): Promise<BoundaryFeatureCollection> {
  const res = await fetch(
    `${proxyBase()}/boundaries/geojson?t=${tenantId}`,
    { headers: { 'X-Tenant-ID': tenantId } },
  );
  if (!res.ok) throw new Error(`geojson ${res.status}`);
  return res.json() as Promise<BoundaryFeatureCollection>;
}
