#!/usr/bin/env node
/**
 * extract-india-state-clips.js
 *
 * Builds Planetiler clip GeoJSON for India state tenants from OSM-derived
 * boundaries/india-boundaries.geojson (produced by generate-osm-boundaries).
 *
 * Run after:
 *   ./scripts/sh/generate-osm-boundaries.sh --country india
 *
 * Usage:
 *   node scripts/extract-india-state-clips.js [path/to/india-boundaries.geojson]
 *
 * Writes:
 *   data/sources/india-states/andhrapradesh.json
 *   data/sources/india-states/manipur.json
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { normalizeAdminName, pickOsmFeatureName } = require('./lib/osm-admin-names');

const REPO_ROOT = path.join(__dirname, '..');
const DEFAULT_INPUT = path.join(REPO_ROOT, 'boundaries/india-boundaries.geojson');
const OUT_DIR = path.join(REPO_ROOT, 'data/sources/india-states');

/** Output slug -> canonical state names / aliases (OSM name or name:en) */
const TARGET_STATES = {
  andhrapradesh: ['andhra pradesh'],
  manipur: ['manipur'],
};

function isStateLevel(props) {
  const al = String(props.admin_level ?? '').trim();
  return al === '4' || al === 4;
}

function buildAliasToSlug() {
  const aliases = {};
  for (const [slug, names] of Object.entries(TARGET_STATES)) {
    for (const n of names) {
      aliases[normalizeAdminName(n)] = slug;
    }
  }
  return aliases;
}

function readFeatureCollection(inputPath) {
  const raw = fs.readFileSync(inputPath, 'utf8');
  return JSON.parse(raw);
}

function collectStateClipFeatures(features, aliases) {
  const bySlug = {};
  for (const slug of Object.keys(TARGET_STATES)) {
    bySlug[slug] = [];
  }
  for (const feat of features) {
    const p = feat.properties || {};
    if (!isStateLevel(p)) continue;
    const key = normalizeAdminName(pickOsmFeatureName(p));
    const slug = aliases[key];
    if (!slug || !feat.geometry) continue;
    bySlug[slug].push({
      type: 'Feature',
      properties: { name: pickOsmFeatureName(p), admin_level: String(p.admin_level ?? '4') },
      geometry: feat.geometry,
    });
  }
  return bySlug;
}

function writeClipFiles(bySlug) {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  let ok = 0;
  for (const [slug, feats] of Object.entries(bySlug)) {
    if (feats.length === 0) {
      console.error(`[WARN] No OSM admin_level=4 state polygon matched for "${slug}"`);
      continue;
    }
    const out = { type: 'FeatureCollection', features: feats };
    const outPath = path.join(OUT_DIR, `${slug}.json`);
    fs.writeFileSync(outPath, JSON.stringify(out));
    console.log(`[OK] ${outPath} (${feats.length} feature(s))`);
    ok++;
  }
  return ok;
}

function main() {
  const inputPath = path.resolve(process.argv[2] || DEFAULT_INPUT);

  if (!fs.existsSync(inputPath)) {
    console.error(`[ERROR] Missing ${inputPath}`);
    console.error('  Generate it first: ./scripts/sh/generate-osm-boundaries.sh --country india');
    process.exit(1);
  }

  try {
    const geo = readFeatureCollection(inputPath);
    const features = geo.features || [];
    const aliases = buildAliasToSlug();
    const bySlug = collectStateClipFeatures(features, aliases);
    const ok = writeClipFiles(bySlug);
    if (ok === 0) {
      console.error('[ERROR] No state clip files written — check OSM names in india-boundaries.geojson');
      process.exit(1);
    }
  } catch (err) {
    console.error('[ERROR] Failed to read or parse GeoJSON:', err.message);
    process.exit(1);
  }
}

main();
