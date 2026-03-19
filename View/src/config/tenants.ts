export interface TenantConfig {
  /** Numeric tenant id as string, used for X-Tenant-ID header and inspector selection. */
  id: string;
  name: string;
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
}

export const TENANTS: TenantConfig[] = [
  {
    id: '1',
    name: 'Bridge Kenya',
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
    source: 'nigeria-jigawa',
    boundarySource: 'nigeria-jigawa-boundaries',
    hdxBoundarySource: 'nigeria-boundaries-hdx',
    lat: 12.0,
    lon: 9.36,
    zoom: 8,
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

