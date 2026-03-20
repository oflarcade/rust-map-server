import maplibregl from 'maplibre-gl';
import { useTileInspector } from './useTileInspector';
import { useMapLayers } from './useMapLayers';
import { bboxFromGeometry } from '../utils/bbox';
import { highlight } from '../utils/highlight';
import type { HierarchyState, HierarchyLGA } from '../types/boundary';

// ---------------------------------------------------------------------------
// Module-level shared state (singleton across all callers)
// ---------------------------------------------------------------------------

let inspectorPopup: maplibregl.Popup | null = null;

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type HighlightItem = { pcode: string; level: 'state' | 'lga' | 'zone'; name?: string };

// ---------------------------------------------------------------------------
// Composable
// ---------------------------------------------------------------------------

export function useMapInteraction() {
  const { getMap } = useTileInspector();
  const { getAllBoundaryFeatures, boundarySummary } = useMapLayers();

  // -- Map interaction setup ------------------------------------------------

  function initMapInteractions() {
    const map = getMap();
    if (!map) return;

    map.on('mouseenter', 'boundary-fill', () => {
      map?.getCanvas().style.setProperty('cursor', 'pointer');
    });

    map.on('mouseleave', 'boundary-fill', () => {
      map?.getCanvas().style.removeProperty('cursor');
    });

    map.on('click', 'boundary-fill', (e) => {
      if (!e.features?.length) return;
      const feature = e.features[0];
      const props = (feature.properties ?? {}) as any;
      const adm2 = props.adm2_name || '';
      const adm1 = props.adm1_name || props.name || '';
      const title = adm2 || adm1;
      const subtitle = adm2 ? adm1 : '';

      if (feature.geometry) {
        const bounds = bboxFromGeometry(feature.geometry as GeoJSON.Geometry);
        map?.fitBounds(bounds, { padding: 60, maxZoom: 14 });
      }
      if (title) {
        boundarySummary.clickedLGA = title;
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '220px' })
          .setLngLat(e.lngLat)
          .setHTML(
            `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">${subtitle ? 'LGA' : 'State'}</div>` +
            `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${title}</div>` +
            (subtitle ? `<div style="font-size:11px;color:#475569;margin-top:3px">${subtitle}</div>` : '')
          )
          .addTo(map!);
      }
    });
  }

  // -- Highlight helpers ----------------------------------------------------

  function setHighlightFeatures(features: GeoJSON.Feature[]) {
    const map = getMap();
    const src = map?.getSource('highlight-overlay') as maplibregl.GeoJSONSource | undefined;
    if (src) src.setData({ type: 'FeatureCollection', features } as any);
  }

  function resetZonePaint() {
    const map = getMap();
    if (map?.getLayer('zones-fill')) map.setPaintProperty('zones-fill', 'fill-opacity', 0);
    if (map?.getLayer('zones-outline')) map.setPaintProperty('zones-outline', 'line-opacity', 1);
  }

  function highlightBoundary(item: HighlightItem | null): void {
    const map = getMap();
    if (!map) return;

    if (!item) {
      setHighlightFeatures([]);
      resetZonePaint();
      return;
    }

    const { pcode, level } = item;

    if (level === 'zone') {
      setHighlightFeatures([]);
      const matchZone: any = ['==', ['get', 'pcode'], pcode];
      if (map.getLayer('zones-fill')) {
        map.setPaintProperty('zones-fill', 'fill-opacity', ['case', matchZone, 0.5, 0]);
      }
      if (map.getLayer('zones-outline')) {
        map.setPaintProperty('zones-outline', 'line-opacity', ['case', matchZone, 1, 0.3]);
      }
      return;
    }

    // state or lga: find geometry in PostGIS GeoJSON features (includes grouped_lga for highlight)
    resetZonePaint();
    const allBoundaryFeatures = getAllBoundaryFeatures();
    const feature = allBoundaryFeatures.find((f) => f.properties?.pcode === pcode);
    setHighlightFeatures(feature ? [feature] : []);
  }

  // -- Fly to / zoom helpers ------------------------------------------------

  function flyToHierarchyItem(state: HierarchyState, lga?: HierarchyLGA): void {
    const map = getMap();
    if (!map) return;
    if (lga && lga.center_lon != null && lga.center_lat != null) {
      const lngLat: [number, number] = [lga.center_lon, lga.center_lat];
      map.once('moveend', () => {
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '220px' })
          .setLngLat(lngLat)
          .setHTML(
            `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">LGA</div>` +
            `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${lga.name}</div>` +
            `<div style="font-size:11px;color:#475569;margin-top:3px">${state.name}</div>`
          )
          .addTo(map!);
      });
      map.flyTo({ center: lngLat, zoom: Math.max(map.getZoom(), 9), duration: 600 });
    } else if (state.center_lon != null && state.center_lat != null) {
      const lngLat: [number, number] = [state.center_lon, state.center_lat];
      map.once('moveend', () => {
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '220px' })
          .setLngLat(lngLat)
          .setHTML(
            `<div style="font-size:11px;text-transform:uppercase;color:#64748b;letter-spacing:0.06em;margin-bottom:3px">State</div>` +
            `<div style="font-size:14px;font-weight:600;color:#0f172a;line-height:1.3">${state.name}</div>`
          )
          .addTo(map!);
      });
      map.flyTo({ center: lngLat, zoom: Math.max(map.getZoom(), 7), duration: 600 });
    }
  }

  function zoomToName(name: string): void {
    const map = getMap();
    if (!map) return;
    const features = map.querySourceFeatures('boundary', { sourceLayer: 'boundaries' });
    const match = features.find((f) => {
      const p = (f.properties ?? {}) as any;
      return p.adm1_name === name || p.adm2_name === name || p.name === name;
    });
    if (match?.geometry) {
      const bounds = bboxFromGeometry(match.geometry as unknown as GeoJSON.Geometry);
      map.fitBounds(bounds, { padding: 60, maxZoom: 14 });
    }
  }

  // -- Return ---------------------------------------------------------------

  return {
    initMapInteractions,
    highlightBoundary,
    flyToHierarchyItem,
    zoomToName,
    setHighlightFeatures,
    resetZonePaint,
    highlight,
  };
}
