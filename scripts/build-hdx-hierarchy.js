#!/usr/bin/env node
/**
 * build-hdx-hierarchy.js
 *
 * Reads HDX COD-AB GeoJSON files and outputs a structured pcode hierarchy
 * JSON per country. This file becomes the source of truth for the admin
 * hierarchy that the BE can use to tag KPIs against pcodes.
 *
 * Pcode structure (UN standard, as-is from HDX):
 *   Country : adm0_pcode  (e.g.  "NG")
 *   State   : adm1_pcode  (e.g.  "NG001")         <- starts with country pcode
 *   LGA     : adm2_pcode  (e.g.  "NG001001")       <- starts with state pcode (for NG/KE)
 *
 * Output: hdx/<country>-hierarchy.json
 *
 * Usage:
 *   node scripts/build-hdx-hierarchy.js
 *   node scripts/build-hdx-hierarchy.js nigeria
 */

const fs   = require("fs");
const path = require("path");

const BASE_DIR = path.resolve(__dirname, "..");
const HDX_DIR  = path.join(BASE_DIR, "hdx");

const COUNTRIES = [
  { prefix: "nigeria",                  name: "Nigeria",                  iso2: "NG" },
  { prefix: "kenya",                    name: "Kenya",                    iso2: "KE" },
  { prefix: "uganda",                   name: "Uganda",                   iso2: "UG" },
  { prefix: "liberia",                  name: "Liberia",                  iso2: "LR" },
  { prefix: "central-african-republic", name: "Central African Republic", iso2: "CF" },
];

const filterArg = process.argv[2] ? process.argv[2].toLowerCase() : null;
const countries = filterArg
  ? COUNTRIES.filter(c => c.prefix === filterArg || c.iso2.toLowerCase() === filterArg)
  : COUNTRIES;

if (filterArg && countries.length === 0) {
  console.error(`Country '${filterArg}' not found. Available: ${COUNTRIES.map(c => c.prefix).join(", ")}`);
  process.exit(1);
}

for (const country of countries) {
  const adm1Path = path.join(HDX_DIR, `${country.prefix}_adm1.geojson`);
  const adm2Path = path.join(HDX_DIR, `${country.prefix}_adm2.geojson`);

  if (!fs.existsSync(adm1Path) || !fs.existsSync(adm2Path)) {
    console.warn(`[SKIP] ${country.name}: HDX files not found (run download-hdx.ps1 first)`);
    continue;
  }

  console.log(`Processing ${country.name}...`);

  const adm1Data = JSON.parse(fs.readFileSync(adm1Path, "utf8"));
  const adm2Data = JSON.parse(fs.readFileSync(adm2Path, "utf8"));

  // Derive country pcode and name from first adm1 feature
  const sample = adm1Data.features[0]?.properties || {};
  const countryPcode = sample.adm0_pcode || country.iso2;
  const countryName  = sample.adm0_name  || country.name;

  // Build state map keyed by adm1_pcode
  const stateMap = {};
  for (const feat of adm1Data.features) {
    const p = feat.properties || {};
    if (!p.adm1_pcode) continue;
    stateMap[p.adm1_pcode] = {
      pcode: p.adm1_pcode,
      name:  p.adm1_name,
      // Include alternate names if present (some HDX packages have multilingual fields)
      ...(p.adm1_name1 ? { name_alt: p.adm1_name1 } : {}),
      area_sqkm:  p.area_sqkm  ?? null,
      center_lat: p.center_lat ?? null,
      center_lon: p.center_lon ?? null,
      lgas: [],
    };
  }

  // Attach LGAs to their parent state
  let lgaTotal = 0;
  let lgaOrphans = 0;
  for (const feat of adm2Data.features) {
    const p = feat.properties || {};
    if (!p.adm2_pcode) continue;

    // Ensure the parent state entry exists (fallback if adm1 file was incomplete)
    if (!stateMap[p.adm1_pcode]) {
      stateMap[p.adm1_pcode] = { pcode: p.adm1_pcode, name: p.adm1_name, lgas: [] };
      lgaOrphans++;
    }

    stateMap[p.adm1_pcode].lgas.push({
      pcode: p.adm2_pcode,
      name:  p.adm2_name,
      ...(p.adm2_name1 ? { name_alt: p.adm2_name1 } : {}),
      area_sqkm:  p.area_sqkm  ?? null,
      center_lat: p.center_lat ?? null,
      center_lon: p.center_lon ?? null,
    });
    lgaTotal++;
  }

  // Sort states and LGAs by pcode for deterministic output
  const states = Object.values(stateMap).sort((a, b) => a.pcode.localeCompare(b.pcode));
  for (const state of states) {
    state.lgas.sort((a, b) => a.pcode.localeCompare(b.pcode));
  }

  const hierarchy = {
    pcode:       countryPcode,
    name:        countryName,
    source:      "HDX COD-AB",
    license:     "CC BY-IGO",
    generated:   new Date().toISOString().slice(0, 10),
    state_count: states.length,
    lga_count:   lgaTotal,
    states,
  };

  const outPath = path.join(HDX_DIR, `${country.prefix}-hierarchy.json`);
  fs.writeFileSync(outPath, JSON.stringify(hierarchy, null, 2));

  const sizeMB = (fs.statSync(outPath).size / 1024 / 1024).toFixed(2);
  console.log(`  -> ${country.prefix}-hierarchy.json (${states.length} states, ${lgaTotal} LGAs, ${sizeMB} MB)`);
  if (lgaOrphans > 0) console.warn(`  [WARN] ${lgaOrphans} states appeared in adm2 but not in adm1 file`);
}

console.log("\nDone. Restart Docker to make hierarchy files available via /boundaries/hierarchy.");
