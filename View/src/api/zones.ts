import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import type { Zone, ZoneCreatePayload, ZoneUpdatePayload } from '../types/zone';

function proxyBase(): string {
  return normalizeBaseUrl(DEFAULT_PROXY_URL);
}

export async function fetchZones(tenantId: string): Promise<Zone[]> {
  const res = await fetch(`${proxyBase()}/admin/zones`, {
    headers: { 'X-Tenant-ID': tenantId },
  });
  if (!res.ok) throw new Error(`zones ${res.status}`);
  const data = await res.json();
  return data.zones ?? [];
}

export async function createZone(tenantId: string, payload: ZoneCreatePayload): Promise<Zone> {
  const res = await fetch(`${proxyBase()}/admin/zones`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': tenantId },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`createZone ${res.status}`);
  return res.json() as Promise<Zone>;
}

export async function updateZone(
  tenantId: string,
  zoneId: number,
  payload: ZoneUpdatePayload,
): Promise<Zone> {
  const res = await fetch(`${proxyBase()}/admin/zones/${zoneId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': tenantId },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`updateZone ${res.status}`);
  return res.json() as Promise<Zone>;
}

export async function deleteZone(tenantId: string, zoneId: number): Promise<void> {
  const res = await fetch(`${proxyBase()}/admin/zones/${zoneId}`, {
    method: 'DELETE',
    headers: { 'X-Tenant-ID': tenantId },
  });
  if (!res.ok) throw new Error(`deleteZone ${res.status}`);
}
