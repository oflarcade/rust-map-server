export type BoundaryFeatureType = 'adm2' | 'adm2_grouped' | 'adm3plus' | 'zone' | 'state' | 'geo_node';

export interface BoundaryFeatureProperties {
  feature_type: BoundaryFeatureType;
  pcode: string;
  name: string;
  color?: string;
  adm1_name?: string;
  adm2_name?: string;
  zone_level?: number;
  zone_type_label?: string;
  parent_pcode?: string;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
}

export type BoundaryFeature = GeoJSON.Feature<GeoJSON.Geometry, BoundaryFeatureProperties>;

export type BoundaryFeatureCollection = GeoJSON.FeatureCollection<
  GeoJSON.Geometry,
  BoundaryFeatureProperties
>;
