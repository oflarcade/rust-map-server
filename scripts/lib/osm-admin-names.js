'use strict';

/**
 * Shared helpers for OSM → GeoJSON features (ogr2ogr multipolygons / admin boundaries).
 * Used by extract-india-state-clips.js and import-hdx-to-pg.js (India path).
 */

function normalizeAdminName(s) {
  return String(s || '')
    .toLowerCase()
    .trim()
    .replace(/\s+/g, ' ');
}

function pickOsmFeatureName(props) {
  if (!props) return '';
  return props['name:en'] || props.name_en || props.name || '';
}

module.exports = { normalizeAdminName, pickOsmFeatureName };
