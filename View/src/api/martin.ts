import { DEFAULT_MARTIN_URL, normalizeBaseUrl } from '../config/urls';
import { resolveBoundarySourceKey } from '../map/inspectorStyle';
import type { TenantConfig } from '../types/tenant';
import type { MartinTileMeta } from '../types/map';

export async function fetchTileMeta(
  sourceId: string,
  martinBaseUrl: string = DEFAULT_MARTIN_URL,
): Promise<MartinTileMeta> {
  const base = normalizeBaseUrl(martinBaseUrl);
  const res = await fetch(`${base}/${sourceId}`);
  if (!res.ok) throw new Error(`tileMeta ${res.status} ${sourceId}`);
  return res.json() as Promise<MartinTileMeta>;
}

export async function loadMartinTileMetadata(
  tenant: TenantConfig,
  martinBaseUrl: string = DEFAULT_MARTIN_URL,
): Promise<{
  baseMeta: MartinTileMeta;
  boundaryMeta: MartinTileMeta;
  baseUrl: string;
  boundaryUrl: string;
}> {
  const base = normalizeBaseUrl(martinBaseUrl);
  const boundarySourceKey = resolveBoundarySourceKey(tenant);

  const [baseMeta, boundaryMeta] = await Promise.all([
    fetchTileMeta(tenant.source, martinBaseUrl).catch(() => ({} as MartinTileMeta)),
    fetchTileMeta(boundarySourceKey, martinBaseUrl).catch(
      () => ({ vector_layers: [], bounds: null }) as MartinTileMeta,
    ),
  ]);

  return {
    baseMeta,
    boundaryMeta,
    baseUrl: `${base}/${tenant.source}/{z}/{x}/{y}`,
    boundaryUrl: `${base}/${boundarySourceKey}/{z}/{x}/{y}`,
  };
}
