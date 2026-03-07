# Martin Tile Service: Usage, Value, and Data Governance (Embedded Innovation Notes)

## Usage Patterns
- **Web (MapLibre GL JS)**: Use `transformRequest` to add `X-Tenant-ID` for `/tiles/{z}/{x}/{y}` and `/boundaries/{z}/{x}/{y}`. Keep styles lean; cap `maxzoom` at 14.
- **Mobile (MapLibre Native / RN @rnmapbox/maps)**: Add custom header `X-Tenant-ID`; prefer simplified styles; enable offline PMTiles packaging for low bandwidth.
- **Direct PMTiles via CDN**: Serve `.pmtiles` with range requests and client-side `pmtiles` protocol to bypass server CPU; gate with signed URLs if needed.
- **Offline MBTiles/SQLite**: Bundle tiles for strict offline use; trade-offs in app size and update cadence.
- **Boundary-only overlay**: Lightweight boundary source layered over any base map when bandwidth-constrained.

## Value Proposition
- **Cost control**: Replace commercial map fees with self-hosted PMTiles; predictable infra spend.
- **Performance**: Range-readable PMTiles + CDN caching reduce latency; Martin is lightweight.
- **Resilience**: Immutable artifacts; swap files atomically and roll back by filename.
- **Multi-tenant simplicity**: One endpoint, header-routed sources; no per-tenant infra.
- **Data ownership**: Full control over basemap and boundary definitions; auditable build pipeline.
- **Portability**: Runs on Docker, Windows, or bare metal; clients are open-source (MapLibre).

## Data Governance
- **Source licensing**: OSM data is ODbL; boundary sources should be CC BY-IGO (HDX COD) or CC BY (geoBoundaries). Avoid non-commercial GADM in production. Track license per source.
- **Provenance tracking**: Record source URL, date, and license for each PMTiles build. Keep a CHANGELOG of tile artifact hashes.
- **PII stance**: Basemap and boundaries should exclude PII; validate generation scripts don’t ingest sensitive attributes.
- **Access controls**: Require `X-Tenant-ID`; use Nginx to reject missing/unknown IDs with `400`. For external exposure, front with auth/CDN signed URLs.
- **Integrity**: Check PMTiles with `pmtiles inspect` or tippecanoe validation; quarantine corrupt files to prevent Martin crashes (InvalidMagicNumber).
- **Versioning & rollback**: Publish with versioned filenames; update Nginx maps to point to the new version; keep previous files for rollback.
- **Caching policy**: Allow CDN/browser caching of tiles; honor `Range` headers. Set conservative `Cache-Control` for boundary layers if frequently updated.
- **Retention**: Store immutable PMTiles; prune superseded artifacts on a schedule while keeping at least one previous version for rollback.
- **Operational controls**: Health endpoints (`/health`, `/catalog`); alert on 5xx/latency; rate-limit abusive tenants at the edge.
- **Data residency**: Place PMTiles/CDN in regions aligned with program requirements; avoid cross-border transfers if restricted.
- **Change management**: Require review for Nginx map updates and new PMTiles ingestion; document zoom ranges and layer names before release.

## Quick Reminders
- Keep files in top-level `pmtiles/` (and `boundaries/`) for discovery; avoid leaving corrupt artifacts.
- Ensure every tenant ID maps to a base (and boundary) source or return explicit errors.
- Prefer z6–14 for regional tiles to avoid blank maps when zoomed out.
