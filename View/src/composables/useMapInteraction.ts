import maplibregl from 'maplibre-gl';
import { useTileInspector } from './useTileInspector';
import { useMapLayers } from './useMapLayers';
import { adminLevelLabel } from '../config/adminLevelLabels';
import { bboxFromGeometry } from '../utils/bbox';
import { highlight } from '../utils/highlight';
import type { HierarchyState, HierarchyLGA } from '../types/boundary';
import type { TenantConfig } from '../types/tenant';

// ---------------------------------------------------------------------------
// Module-level shared state (singleton across all callers)
// ---------------------------------------------------------------------------

let inspectorPopup: maplibregl.Popup | null = null;

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type HighlightItem = { pcode: string; level: 'state' | 'lga' | 'zone'; name?: string };

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** Category line + title + optional parent context — tuned for long OCHA labels (no harsh all-caps). */
function boundaryPopupHtml(kindLabel: string, title: string, parentLine?: string): string {
  const k = escapeHtml(kindLabel);
  const t = escapeHtml(title);
  const p = parentLine ? escapeHtml(parentLine) : '';
  return (
    `<div style="padding:1px 0 2px">` +
    `<div style="font-size:10px;font-weight:600;color:#64748b;letter-spacing:0.02em;line-height:1.35;margin-bottom:4px">${k}</div>` +
    `<div style="font-size:15px;font-weight:600;color:#0f172a;line-height:1.35">${t}</div>` +
    (p
      ? `<div style="font-size:11px;color:#475569;margin-top:6px;line-height:1.45;border-top:1px solid #e2e8f0;padding-top:5px">${p}</div>`
      : '') +
    `</div>`
  );
}

function leafKindFromTileProps(props: Record<string, unknown>, tenant: TenantConfig): string {
  const raw = props.level_label;
  if (typeof raw === 'string' && raw.trim()) return raw.trim();

  const adm3 = String(props.adm3_name ?? '').trim();
  const adm2 = String(props.adm2_name ?? '').trim();
  const depth = adm3 ? 3 : adm2 ? 2 : 1;
  const cc = tenant.countryCode;

  const fromTable = adminLevelLabel(cc, depth);
  if (fromTable) return fromTable;
  if (depth > 1) return tenant.lgaLabel?.trim() || 'Local area';
  return 'Administrative area';
}

function subtitleFromTileProps(props: Record<string, unknown>): string {
  const adm3 = String(props.adm3_name ?? '').trim();
  const adm2 = String(props.adm2_name ?? '').trim();
  const adm1 = String(props.adm1_name ?? props.name ?? '').trim();
  if (adm3) {
    const parts = [adm2, adm1].filter(Boolean);
    return parts.join(' · ');
  }
  if (adm2 && adm1) return adm1;
  return '';
}

// ---------------------------------------------------------------------------
// Composable
// ---------------------------------------------------------------------------

export function useMapInteraction() {
  const { getMap, currentTenant } = useTileInspector();
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
      const props = (feature.properties ?? {}) as Record<string, unknown>;
      const adm3 = String(props.adm3_name ?? '').trim();
      const adm2 = String(props.adm2_name ?? '').trim();
      const adm1 = String(props.adm1_name ?? props.name ?? '').trim();
      const title = adm3 || adm2 || adm1;
      const subtitle = subtitleFromTileProps(props);
      const tenant = currentTenant.value;
      const kindLabel = leafKindFromTileProps(props, tenant);

      if (feature.geometry) {
        const bounds = bboxFromGeometry(feature.geometry as GeoJSON.Geometry);
        map?.fitBounds(bounds, { padding: 60, maxZoom: 14 });
      }
      if (title) {
        boundarySummary.clickedLGA = title;
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '280px', className: 'boundary-inspector-popup' })
          .setLngLat(e.lngLat)
          .setHTML(boundaryPopupHtml(kindLabel, title, subtitle || undefined))
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
    const tenant = currentTenant.value;
    const cc = tenant.countryCode;
    if (lga && lga.center_lon != null && lga.center_lat != null) {
      const lngLat: [number, number] = [lga.center_lon, lga.center_lat];
      const childKind =
        lga.level_label?.trim() ||
        tenant.lgaLabel?.trim() ||
        adminLevelLabel(cc, 2) ||
        'Local area';
      const parentLine = state.name;
      map.once('moveend', () => {
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '280px', className: 'boundary-inspector-popup' })
          .setLngLat(lngLat)
          .setHTML(boundaryPopupHtml(childKind, lga.name, parentLine))
          .addTo(map!);
      });
      map.flyTo({ center: lngLat, zoom: Math.max(map.getZoom(), 9), duration: 600 });
    } else if (state.center_lon != null && state.center_lat != null) {
      const lngLat: [number, number] = [state.center_lon, state.center_lat];
      const stateKind =
        state.level_label?.trim() ||
        adminLevelLabel(cc, 1) ||
        'Administrative area';
      map.once('moveend', () => {
        if (inspectorPopup) { inspectorPopup.remove(); inspectorPopup = null; }
        inspectorPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '280px', className: 'boundary-inspector-popup' })
          .setLngLat(lngLat)
          .setHTML(boundaryPopupHtml(stateKind, state.name))
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
