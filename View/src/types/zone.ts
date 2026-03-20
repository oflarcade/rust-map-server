export interface Zone {
  id: number;
  zone_pcode: string;
  zone_name: string;
  color: string | null;
  zone_level: number;
  zone_type_label: string | null;
  parent_pcode: string | null;
  children_type: 'lga' | 'zone';
  constituent_pcodes: string[];
  updated_by: string | null;
}

export interface ZoneCreatePayload {
  zone_name: string;
  zone_type_label: string | null;
  color: string;
  constituent_pcodes: string[];
  children_type: 'lga' | 'zone';
  parent_pcode?: string;
}

export type ZoneUpdatePayload = ZoneCreatePayload;
