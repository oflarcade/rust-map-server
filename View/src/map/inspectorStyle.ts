import maplibregl from 'maplibre-gl';
import type { TenantConfig } from '../config/tenants';
import { DEFAULT_MARTIN_URL, normalizeBaseUrl } from '../config/urls';

async function fetchJson<T = any>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return (await res.json()) as T;
}

function getSourceLayer(meta: any, preferred: string): string {
  const layers = Array.isArray(meta?.vector_layers) ? meta.vector_layers : [];
  const found = layers.find((l: any) => l && l.id === preferred);
  return found ? found.id : '';
}

export function resolveBoundarySourceKey(tenant: TenantConfig, useHdx = false): string {
  if (useHdx && tenant.hdxBoundarySource) return tenant.hdxBoundarySource;
  return tenant.boundarySource;
}

export async function loadMartinTileMetadata(
  tenant: TenantConfig,
  martinBaseUrl: string = DEFAULT_MARTIN_URL,
): Promise<{ baseMeta: any; boundaryMeta: any; baseUrl: string; boundaryUrl: string }> {
  const base = normalizeBaseUrl(martinBaseUrl);
  const boundarySourceKey = resolveBoundarySourceKey(tenant);

  const [baseMeta, boundaryMeta] = await Promise.all([
    fetchJson<any>(`${base}/${tenant.source}`).catch(() => ({})),
    fetchJson<any>(`${base}/${boundarySourceKey}`).catch(() => ({ vector_layers: [], bounds: null })),
  ]);

  return {
    baseMeta,
    boundaryMeta,
    baseUrl: `${base}/${tenant.source}/{z}/{x}/{y}`,
    boundaryUrl: `${base}/${boundarySourceKey}/{z}/{x}/{y}`,
  };
}

export function buildInspectorStyle(
  baseMeta: any,
  boundaryMeta: any,
  baseTileUrl: string,
  boundaryTileUrl: string,
): maplibregl.StyleSpecification {
  const styleLayers: maplibregl.LayerSpecification[] = [];
  const present = (name: string) => getSourceLayer(baseMeta, name);

  styleLayers.push({
    id: 'background',
    type: 'background',
    paint: { 'background-color': '#f5f3ee' },
  });

  if (present('water')) {
    styleLayers.push({
      id: 'base-water',
      type: 'fill',
      source: 'base',
      'source-layer': 'water',
      paint: { 'fill-color': '#a0cfdf' },
    } as any);
  }

  if (present('landcover')) {
    styleLayers.push({
      id: 'base-landcover',
      type: 'fill',
      source: 'base',
      'source-layer': 'landcover',
      paint: { 'fill-color': '#d6ead1', 'fill-opacity': 0.55 },
    } as any);
  }

  if (present('landuse')) {
    styleLayers.push({
      id: 'base-landuse',
      type: 'fill',
      source: 'base',
      'source-layer': 'landuse',
      paint: { 'fill-color': '#ece9d8', 'fill-opacity': 0.45 },
    } as any);
  }

  if (present('transportation')) {
    styleLayers.push({
      id: 'base-roads',
      type: 'line',
      source: 'base',
      'source-layer': 'transportation',
      paint: { 'line-color': '#888', 'line-width': 1 },
    } as any);
    styleLayers.push({
      id: 'base-roads-major',
      type: 'line',
      source: 'base',
      'source-layer': 'transportation',
      filter: ['in', 'class', 'primary', 'secondary', 'trunk', 'motorway'],
      paint: { 'line-color': '#f59e0b', 'line-width': 2 },
    } as any);
  }

  if (present('building')) {
    styleLayers.push({
      id: 'base-buildings',
      type: 'fill',
      source: 'base',
      'source-layer': 'building',
      minzoom: 12,
      paint: { 'fill-color': '#d7c6a7', 'fill-opacity': 0.65 },
    } as any);
  }

  if (present('place')) {
    styleLayers.push({
      id: 'base-place-label',
      type: 'symbol',
      source: 'base',
      'source-layer': 'place',
      layout: {
        'text-field': ['coalesce', ['get', 'name:latin'], ['get', 'name']],
        'text-size': 11,
      },
      paint: {
        'text-color': '#2c2c2c',
        'text-halo-color': '#fff',
        'text-halo-width': 1.2,
      },
    } as any);
  }

  const boundaryLayer =
    getSourceLayer(boundaryMeta, 'boundaries') ||
    (Array.isArray(boundaryMeta?.vector_layers) && boundaryMeta.vector_layers[0]?.id) ||
    '';

  if (boundaryLayer) {
    const lgaFilter: any = ['has', 'adm2_name'];
    const stateFilter: any = ['!', ['has', 'adm2_name']];

    styleLayers.push({
      id: 'boundary-fill',
      type: 'fill',
      source: 'boundary',
      'source-layer': boundaryLayer,
      filter: lgaFilter,
      paint: { 'fill-color': '#60a5fa', 'fill-opacity': 0.15 },
    } as any);

    styleLayers.push({
      id: 'boundary-state-line',
      type: 'line',
      source: 'boundary',
      'source-layer': boundaryLayer,
      filter: stateFilter,
      paint: { 'line-color': '#2563eb', 'line-width': 2 },
    } as any);

    styleLayers.push({
      id: 'boundary-lga-line',
      type: 'line',
      source: 'boundary',
      'source-layer': boundaryLayer,
      filter: lgaFilter,
      paint: { 'line-color': '#6366f1', 'line-width': 1 },
    } as any);

    styleLayers.push({
      id: 'boundary-state-label',
      type: 'symbol',
      source: 'boundary',
      'source-layer': boundaryLayer,
      filter: stateFilter,
      layout: {
        'text-field': ['coalesce', ['get', 'adm1_name'], ['get', 'name']],
        'text-size': 13,
        'text-max-width': 8,
        'text-allow-overlap': false,
      },
      paint: {
        'text-color': '#1e3a5f',
        'text-halo-color': '#fff',
        'text-halo-width': 1.5,
      },
    } as any);

    styleLayers.push({
      id: 'boundary-lga-label',
      type: 'symbol',
      source: 'boundary',
      'source-layer': boundaryLayer,
      minzoom: 8,
      filter: lgaFilter,
      layout: {
        'text-field': ['coalesce', ['get', 'adm2_name'], ['get', 'name']],
        'text-size': 10,
        'text-max-width': 6,
        'text-allow-overlap': false,
      },
      paint: {
        'text-color': '#0f172a',
        'text-halo-color': '#fff',
        'text-halo-width': 1,
      },
    } as any);
  }

  return {
    version: 8,
    glyphs: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',
    sources: {
      base: {
        type: 'vector',
        tiles: [baseTileUrl],
        minzoom: baseMeta?.minzoom ?? 0,
        maxzoom: baseMeta?.maxzoom ?? 14,
      },
      boundary: {
        type: 'vector',
        tiles: [boundaryTileUrl],
        minzoom: boundaryMeta?.minzoom ?? 0,
        maxzoom: boundaryMeta?.maxzoom ?? 14,
      },
    },
    layers: styleLayers,
  } as maplibregl.StyleSpecification;
}

