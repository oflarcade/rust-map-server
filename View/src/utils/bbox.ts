export function bboxFromGeometry(
  geometry: GeoJSON.Geometry,
): [[number, number], [number, number]] {
  let minLng = Infinity;
  let minLat = Infinity;
  let maxLng = -Infinity;
  let maxLat = -Infinity;

  function walk(coords: unknown): void {
    if (Array.isArray(coords) && typeof coords[0] === 'number') {
      if (coords[0] < minLng) minLng = coords[0];
      if (coords[1] < minLat) minLat = coords[1];
      if (coords[0] > maxLng) maxLng = coords[0];
      if (coords[1] > maxLat) maxLat = coords[1];
    } else if (Array.isArray(coords)) {
      coords.forEach(walk);
    }
  }

  // @ts-expect-error coordinates is valid for all geometry types here
  walk(geometry.coordinates);
  return [
    [minLng, minLat],
    [maxLng, maxLat],
  ];
}
