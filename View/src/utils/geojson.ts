import maplibregl from 'maplibre-gl';

export function featuresToBounds(features: GeoJSON.Feature[]): maplibregl.LngLatBounds | null {
  const bounds = new maplibregl.LngLatBounds();
  for (const f of features) {
    if (!f.geometry) continue;
    const geom = f.geometry as GeoJSON.Polygon | GeoJSON.MultiPolygon;
    if (!('coordinates' in geom)) continue;
    const coords =
      geom.type === 'MultiPolygon'
        ? (geom.coordinates as number[][][][]).flat(2)
        : (geom.coordinates as number[][][]).flat(1);
    coords.forEach((c: number[]) => {
      try { bounds.extend(c as [number, number]); } catch { /* skip invalid coord */ }
    });
  }
  return bounds.isEmpty() ? null : bounds;
}
