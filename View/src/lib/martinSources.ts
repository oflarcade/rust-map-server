/**
 * Martin vector source ids (PMTiles basename without `.pmtiles`).
 * Must match files under `data/pmtiles` and `data/boundaries` and `tenants.tile_source` / `boundary_source`.
 *
 * Nigeria per-state tiles from `generate-states.sh` / `generate-states.ps1` use:
 *   - Base: `nigeria-<state-slug>`
 *   - Bounds: `nigeria-<state-slug>-boundaries`
 */

/** e.g. "Delta" -> "delta", "Akwa Ibom" -> "akwa-ibom" */
export function slugifyStateName(name: string): string {
  return name.toLowerCase().replace(/\s+/g, '-');
}

/** One or more state slugs joined as in Planetiler output (multi-state = slug1-slug2-...) */
export function nigeriaTileSource(stateSlugs: string[]): string {
  return `nigeria-${stateSlugs.join('-')}`;
}

export function nigeriaBoundarySource(stateSlugs: string[]): string {
  return `${nigeriaTileSource(stateSlugs)}-boundaries`;
}

export function deriveNigeriaMartinSources(stateNames: string[]): { tile: string; boundary: string } {
  const slugs = stateNames.map(slugifyStateName);
  return { tile: nigeriaTileSource(slugs), boundary: nigeriaBoundarySource(slugs) };
}
