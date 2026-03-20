export interface DataControlRow {
  id: string;
  group: 'base' | 'boundary';
  label: string;
  layers: string[];
  countryLayerPrefixes?: string[];
  visible: boolean;
}

export interface MartinVectorLayer {
  id: string;
  fields?: Record<string, string>;
  description?: string;
  minzoom?: number;
  maxzoom?: number;
}

export interface MartinTileMeta {
  name?: string;
  description?: string;
  minzoom?: number;
  maxzoom?: number;
  bounds?: [number, number, number, number] | null;
  center?: [number, number, number] | null;
  vector_layers?: MartinVectorLayer[];
  format?: string;
  tilejson?: string;
}
