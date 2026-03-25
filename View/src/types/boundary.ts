export interface BoundarySummary {
  states: number;
  lgas: number;
  stateNames: string[];
  lgaNames: string[];
  clickedLGA: string;
}

export interface HierarchyLGA {
  pcode: string;
  name: string;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
}

export interface HierarchyZone {
  zone_pcode: string;
  zone_name: string;
  name?: string;
  level_label?: string;
  color?: string;
  parent_pcode: string;
  constituent_pcodes: string[];
  zone_level?: number;
  zone_type_label?: string;
  is_zone?: boolean;
  children?: HierarchyChild[];
}

export interface HierarchyAdmNode {
  pcode: string;
  name: string;
  level?: number;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
  is_zone?: false;
  children?: HierarchyAdmNode[];
}

export type HierarchyChild = HierarchyZone | HierarchyAdmNode;

export interface HierarchyState {
  pcode: string;
  name: string;
  level_label?: string;
  area_sqkm?: number;
  center_lat?: number;
  center_lon?: number;
  adm2s: HierarchyLGA[];
  zones?: HierarchyZone[];
  children?: HierarchyChild[];
}

export interface HierarchyData {
  pcode: string;
  name: string;
  source?: string;
  license?: string;
  state_count?: number;
  adm2_count?: number;
  states: HierarchyState[];
}
