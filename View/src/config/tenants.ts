export interface TenantConfig {
  /** Numeric tenant id as string, used for X-Tenant-ID header and inspector selection. */
  id: string;
  name: string;
  /** ISO country code (e.g. 'KE', 'NG'). */
  countryCode: string;
  /** Default map center latitude. */
  lat: number;
  /** Default map center longitude. */
  lon: number;
  /** Default zoom level. */
  zoom: number;
  /** Martin base tiles source key (e.g. kenya-detailed). */
  source: string;
  /** Default boundary tiles source key (OSM-derived boundaries). */
  boundarySource: string;
  /** Optional HDX COD-AB boundary tiles source key for this tenant. */
  hdxBoundarySource?: string | null;
  /** Term for the lowest-level admin unit this tenant manages. Defaults to 'LGA'. */
  lgaLabel?: string;
  /** Ordered zone type labels for this tenant's zone hierarchy (parent → leaf). */
  zoneTypes?: string[];
}

export const TENANTS: TenantConfig[] = [
  {
    id: '1',
    name: 'Bridge Kenya',
    countryCode: 'KE',
    source: 'kenya-detailed',
    boundarySource: 'kenya-boundaries',
    hdxBoundarySource: 'kenya-boundaries-hdx',
    lat: 0.0,
    lon: 37.9,
    zoom: 6,
  },
  {
    id: '2',
    name: 'Bridge Uganda',
    countryCode: 'UG',
    source: 'uganda-detailed',
    boundarySource: 'uganda-boundaries',
    hdxBoundarySource: 'uganda-boundaries-hdx',
    lat: 1.4,
    lon: 32.3,
    zoom: 6,
  },
  {
    id: '3',
    name: 'Bridge Nigeria (Lagos+Osun)',
    countryCode: 'NG',
    source: 'nigeria-lagos-osun',
    boundarySource: 'nigeria-lagos-osun-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 7.0,
    lon: 3.9,
    zoom: 8,
  },
  {
    id: '4',
    name: 'Bridge Liberia',
    countryCode: 'LR',
    source: 'liberia-detailed',
    boundarySource: 'liberia-boundaries',
    hdxBoundarySource: 'liberia-boundaries-hdx',
    lat: 6.4,
    lon: -9.4,
    zoom: 7,
  },
  {
    id: '5',
    name: 'Bridge India (AP)',
    countryCode: 'IN',
    source: 'india-andhrapradesh',
    boundarySource: 'india-boundaries',
    hdxBoundarySource: null,
    lat: 15.9,
    lon: 80.0,
    zoom: 7,
  },
  {
    id: '9',
    name: 'EdoBEST (Edo)',
    countryCode: 'NG',
    source: 'nigeria-edo',
    boundarySource: 'nigeria-edo-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 6.6,
    lon: 5.9,
    zoom: 8,
  },
  {
    id: '11',
    name: 'EKOEXCEL (Lagos)',
    countryCode: 'NG',
    source: 'nigeria-lagos',
    boundarySource: 'nigeria-lagos-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 6.5,
    lon: 3.4,
    zoom: 9,
  },
  {
    id: '12',
    name: 'Rwanda EQUIP',
    countryCode: 'RW',
    source: 'rwanda-detailed',
    boundarySource: 'rwanda-boundaries',
    hdxBoundarySource: null,
    lat: -1.9,
    lon: 29.9,
    zoom: 8,
  },
  {
    id: '14',
    name: 'Kwara Learn',
    countryCode: 'NG',
    source: 'nigeria-kwara',
    boundarySource: 'nigeria-kwara-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 8.5,
    lon: 4.5,
    zoom: 8,
  },
  {
    id: '15',
    name: 'Manipur Education',
    countryCode: 'IN',
    source: 'india-manipur',
    boundarySource: 'india-boundaries',
    hdxBoundarySource: null,
    lat: 24.8,
    lon: 93.9,
    zoom: 8,
  },
  {
    id: '16',
    name: 'Bayelsa Prime',
    countryCode: 'NG',
    source: 'nigeria-bayelsa',
    boundarySource: 'nigeria-bayelsa-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 4.9,
    lon: 6.3,
    zoom: 8,
  },
  {
    id: '17',
    name: 'Espoir CAR',
    countryCode: 'CF',
    source: 'central-african-republic-detailed',
    boundarySource: 'central-african-republic-boundaries',
    hdxBoundarySource: 'central-african-republic-boundaries-hdx',
    lat: 6.6,
    lon: 20.9,
    zoom: 6,
  },
  {
    id: '18',
    name: 'Jigawa Unite',
    countryCode: 'NG',
    source: 'nigeria-jigawa',
    boundarySource: 'nigeria-jigawa-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 12.0,
    lon: 9.36,
    zoom: 8,
    zoneTypes: ['Senatorial District', 'Emirate', 'Federal Constituency'],
  },
];

/** Maps tenant id to the HDX hierarchy JSON slug (filename prefix). */
export const HIERARCHY_MAP: Record<string, string> = {
  '1': 'kenya',
  '2': 'uganda',
  '3': 'nigeria',
  '4': 'liberia',
  '9': 'nigeria',
  '11': 'nigeria',
  '14': 'nigeria',
  '16': 'nigeria',
  '17': 'central-african-republic',
  '18': 'nigeria',
};

export function getTenantById(id: string): TenantConfig | undefined {
  return TENANTS.find((t) => t.id === id);
}

/** Country-level defaults for lat/lon/zoom used when a tenant is added via DB but not in the static list. */
const COUNTRY_DEFAULTS: Record<string, { lat: number; lon: number; zoom: number }> = {
  KE: { lat: 0.0, lon: 37.9, zoom: 6 },
  UG: { lat: 1.4, lon: 32.3, zoom: 6 },
  NG: { lat: 9.0, lon: 8.0,  zoom: 6 },
  LR: { lat: 6.4, lon: -9.4, zoom: 7 },
  IN: { lat: 20.0, lon: 78.0, zoom: 5 },
  RW: { lat: -1.9, lon: 29.9, zoom: 8 },
  CF: { lat: 6.6, lon: 20.9,  zoom: 6 },
};

/**
 * Fetch tenant list from GET /admin/tenants and merge with static defaults.
 * Falls back to the static TENANTS array if the API is unreachable or returns an error.
 */
export async function loadTenants(baseUrl: string): Promise<TenantConfig[]> {
  try {
    const res = await fetch(`${baseUrl}/admin/tenants`);
    if (!res.ok) return TENANTS;
    const data = await res.json();
    const apiTenants: Array<{
      tenant_id: number; country_code: string; country_name: string;
      tile_source: string; boundary_source: string; hdx_prefix: string;
    }> = data.tenants ?? [];

    if (apiTenants.length === 0) return TENANTS;

    return apiTenants.map(at => {
      const id       = String(at.tenant_id);
      const existing = getTenantById(id);
      const geo      = COUNTRY_DEFAULTS[at.country_code] ?? { lat: 0, lon: 0, zoom: 5 };
      return {
        id,
        name:               existing?.name ?? at.country_name ?? id,
        countryCode:        at.country_code,
        lat:                existing?.lat     ?? geo.lat,
        lon:                existing?.lon     ?? geo.lon,
        zoom:               existing?.zoom    ?? geo.zoom,
        source:             at.tile_source    ?? existing?.source ?? '',
        boundarySource:     at.boundary_source ?? existing?.boundarySource ?? '',
        hdxBoundarySource:  existing?.hdxBoundarySource,
        lgaLabel:           existing?.lgaLabel,
        zoneTypes:          existing?.zoneTypes,
      };
    });
  } catch {
    return TENANTS;
  }
}

