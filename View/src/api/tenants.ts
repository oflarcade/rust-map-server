import { DEFAULT_PROXY_URL, normalizeBaseUrl } from '../config/urls';
import { TENANTS, getTenantById } from '../config/tenants';
import type { TenantConfig } from '../types/tenant';

const COUNTRY_DEFAULTS: Record<string, { lat: number; lon: number; zoom: number }> = {
  KE: { lat: 0.0, lon: 37.9, zoom: 6 },
  UG: { lat: 1.4, lon: 32.3, zoom: 6 },
  NG: { lat: 9.0, lon: 8.0,  zoom: 6 },
  LR: { lat: 6.4, lon: -9.4, zoom: 7 },
  IN: { lat: 20.0, lon: 78.0, zoom: 5 },
  RW: { lat: -1.9, lon: 29.9, zoom: 8 },
  CF: { lat: 6.6, lon: 20.9,  zoom: 6 },
};

interface ApiTenantRow {
  tenant_id: number;
  country_code: string;
  country_name: string;
  tile_source: string;
  boundary_source: string;
  hdx_prefix: string;
}

export async function fetchApiTenants(): Promise<TenantConfig[]> {
  const base = normalizeBaseUrl(DEFAULT_PROXY_URL);
  try {
    const res = await fetch(`${base}/admin/tenants`);
    if (!res.ok) return TENANTS;
    const data = await res.json();
    const apiTenants: ApiTenantRow[] = data.tenants ?? [];
    if (apiTenants.length === 0) return TENANTS;
    return apiTenants.map((at) => {
      const id = String(at.tenant_id);
      const existing = getTenantById(id);
      const geo = COUNTRY_DEFAULTS[at.country_code] ?? { lat: 0, lon: 0, zoom: 5 };
      return {
        id,
        name:              existing?.name ?? at.country_name ?? id,
        countryCode:       at.country_code,
        lat:               existing?.lat  ?? geo.lat,
        lon:               existing?.lon  ?? geo.lon,
        zoom:              existing?.zoom ?? geo.zoom,
        source:            at.tile_source    ?? existing?.source ?? '',
        boundarySource:    at.boundary_source ?? existing?.boundarySource ?? '',
        hdxBoundarySource: existing?.hdxBoundarySource,
        lgaLabel:          existing?.lgaLabel,
        zoneTypes:         existing?.zoneTypes,
      };
    });
  } catch {
    return TENANTS;
  }
}
