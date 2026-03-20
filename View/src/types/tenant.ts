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
