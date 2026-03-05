#!/usr/bin/env node
/**
 * split-boundaries.js
 *
 * Splits nigeria-boundaries.geojson into per-tenant boundary GeoJSON files.
 * Each file contains:
 *   - The state polygon(s) (admin_level=4, matched by name)
 *   - All LGA polygons (admin_level=6) whose centroid falls inside the state bbox
 *
 * Usage:
 *   node scripts/split-boundaries.js
 *
 * Output: boundaries/nigeria-{state}-boundaries.geojson for each tenant
 */

const fs = require("fs");
const path = require("path");

const BASE_DIR = path.resolve(__dirname, "..");
const INPUT = path.join(BASE_DIR, "boundaries", "nigeria-boundaries.geojson");
const OUTPUT_DIR = path.join(BASE_DIR, "boundaries");

// Tenant definitions: outputName → state name(s)
const TENANTS = [
  { output: "nigeria-edo-boundaries", states: ["Edo"] },
  { output: "nigeria-lagos-boundaries", states: ["Lagos"] },
  { output: "nigeria-kwara-boundaries", states: ["Kwara"] },
  { output: "nigeria-bayelsa-boundaries", states: ["Bayelsa"] },
  { output: "nigeria-jigawa-boundaries", states: ["Jigawa"] },
  { output: "nigeria-lagos-osun-boundaries", states: ["Lagos", "Osun"] },
];

console.log("Reading", INPUT, "...");
const data = JSON.parse(fs.readFileSync(INPUT, "utf8"));
console.log(`Loaded ${data.features.length} features`);

const stateFeatures = data.features.filter(
  (f) => f.properties.admin_level === "4",
);
const lgaFeatures = data.features.filter(
  (f) => f.properties.admin_level === "6",
);
console.log(`  States (admin_level=4): ${stateFeatures.length}`);
console.log(`  LGAs   (admin_level=6): ${lgaFeatures.length}`);

// Compute bounding box from a GeoJSON geometry
function getBBox(geometry) {
  const coords = geometry.coordinates.flat(Infinity);
  let minLng = Infinity,
    maxLng = -Infinity,
    minLat = Infinity,
    maxLat = -Infinity;
  for (let i = 0; i < coords.length; i += 2) {
    const lng = coords[i];
    const lat = coords[i + 1];
    if (lng < minLng) minLng = lng;
    if (lng > maxLng) maxLng = lng;
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
  }
  return [minLng, minLat, maxLng, maxLat];
}

// Compute centroid of a feature (simple average of all coords)
function getCentroid(geometry) {
  const coords = geometry.coordinates.flat(Infinity);
  let sumLng = 0,
    sumLat = 0,
    count = 0;
  for (let i = 0; i < coords.length; i += 2) {
    sumLng += coords[i];
    sumLat += coords[i + 1];
    count++;
  }
  return [sumLng / count, sumLat / count];
}

// Ray-casting point-in-polygon for a single ring
function pointInRing(point, ring) {
  let inside = false;
  const [px, py] = point;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    const intersect =
      yi > py !== yj > py && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

// Test point against a GeoJSON geometry (Polygon or MultiPolygon, outer ring only)
function pointInGeometry(point, geometry) {
  if (geometry.type === "Polygon") {
    return pointInRing(point, geometry.coordinates[0]);
  }
  if (geometry.type === "MultiPolygon") {
    return geometry.coordinates.some((poly) => pointInRing(point, poly[0]));
  }
  return false;
}

for (const tenant of TENANTS) {
  console.log(`\nProcessing ${tenant.output}...`);

  // Find matching state features
  const matchedStates = stateFeatures.filter((f) =>
    tenant.states.includes(f.properties.name),
  );
  console.log(
    `  Matched states: ${matchedStates.map((f) => f.properties.name).join(", ")}`,
  );

  if (matchedStates.length === 0) {
    console.error(`  ERROR: No state found for ${tenant.states.join(", ")}`);
    continue;
  }

  // Find LGAs whose centroid falls inside the actual state polygon(s)
  const matchedLGAs = lgaFeatures.filter((f) => {
    const centroid = getCentroid(f.geometry);
    return matchedStates.some((s) => pointInGeometry(centroid, s.geometry));
  });
  console.log(`  Matched LGAs: ${matchedLGAs.length}`);

  // Build output GeoJSON
  const outputFeatures = [...matchedStates, ...matchedLGAs];
  const output = {
    type: "FeatureCollection",
    name: tenant.output,
    features: outputFeatures,
  };

  const outputPath = path.join(OUTPUT_DIR, `${tenant.output}.geojson`);
  fs.writeFileSync(outputPath, JSON.stringify(output));
  const sizeMB = (fs.statSync(outputPath).size / 1024 / 1024).toFixed(2);
  console.log(
    `  Written: ${outputPath} (${outputFeatures.length} features, ${sizeMB} MB)`,
  );
}

console.log("\nDone! Now convert to pmtiles with tippecanoe.");
console.log("See the Docker commands in the output above.");
