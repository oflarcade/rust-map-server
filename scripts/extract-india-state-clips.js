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

const REPO_ROOT = path.join(__dirname, '..');
const DEFAULT_INPUT = path.join(REPO_ROOT, 'boundaries/india-boundaries.geojson');
const OUT_DIR = path.join(REPO_ROOT, 'data/sources/india-states');

/** Output slug -> canonical state names / aliases (OSM name or name:en) */
const TARGET_STATES = {
  andhrapradesh: ['andhra pradesh'],
  manipur: ['manipur'],
};

function norm(s) {
  return String(s || '')
    .toLowerCase()
    .trim()
    .replace(/\s+/g, ' ');
}

function pickName(props) {
  if (!props) return '';
  return props['name:en'] || props.name_en || props.name || '';
}

function isStateLevel(props) {
  const al = String(props.admin_level ?? '').trim();
  return al === '4' || al === 4;
}

function main() {
  const inputPath = path.resolve(process.argv[2] || DEFAULT_INPUT);

  if (!fs.existsSync(inputPath)) {
    console.error(`[ERROR] Missing ${inputPath}`);
    console.error('  Generate it first: ./scripts/sh/generate-osm-boundaries.sh --country india');
    process.exit(1);
  }

  const raw = fs.readFileSync(inputPath, 'utf8');
  const geo = JSON.parse(raw);
  const features = geo.features || [];

  const bySlug = {};
  for (const slug of Object.keys(TARGET_STATES)) {
    bySlug[slug] = [];
  }

  const aliases = {};
  for (const [slug, names] of Object.entries(TARGET_STATES)) {
    for (const n of names) {
      aliases[norm(n)] = slug;
    }
  }

  for (const feat of features) {
    const p = feat.properties || {};
    if (!isStateLevel(p)) continue;
    const key = norm(pickName(p));
    const slug = aliases[key];
    if (!slug) continue;
    if (!feat.geometry) continue;
    bySlug[slug].push({
      type: 'Feature',
      properties: { name: pickName(p), admin_level: String(p.admin_level ?? '4') },
      geometry: feat.geometry,
    });
  }

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

  if (ok === 0) {
    console.error('[ERROR] No state clip files written — check OSM names in india-boundaries.geojson');
    process.exit(1);
  }
}

main();
