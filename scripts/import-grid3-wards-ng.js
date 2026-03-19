#!/usr/bin/env node
// import-grid3-wards-ng.js
// Downloads GRID3 Nigeria ward boundaries and imports them into adm_features
// at adm_level=3, level_label='Ward', with parent_pcode pointing to LGA.
//
// Pcode derivation (no spatial join needed):
//   lgacode "18001" -> parent LGA pcode "NG018001" ("NG0" + lgacode)
//   Ward pcode: lga_pcode + 3-digit seq, sorted alphabetically by wardname within LGA
//   e.g. "NG018001001", "NG018001002", ...
//
// Usage:
//   node scripts/import-grid3-wards-ng.js
//   node scripts/import-grid3-wards-ng.js --state NG018
//   node scripts/import-grid3-wards-ng.js --dry-run
//
// Data source: GRID3 NGA Operational Wards v1.0 (CC BY 4.0)
//   https://data.grid3.org/datasets/GRID3::grid3-nga-operational-wards-v1-0/about

'use strict';

const https  = require('https');
const { Client } = require('pg');

// Mapping: HDX state pcode -> GRID3 statecode field value
const STATE_CODE_MAP = {
  'NG018': 'JI',  // Jigawa
};

// Mapping: HDX state pcode -> tenant ID
const STATE_TENANT_MAP = {
  'NG018': 18,  // Jigawa Unite
};

const DEFAULT_STATE = 'NG018';

const PG_CONFIG = {
  host:     process.env.PGHOST     || 'localhost',
  port:     parseInt(process.env.PGPORT || '5432'),
  database: process.env.PGDATABASE || 'mapserver',
  user:     process.env.PGUSER     || 'mapserver',
  password: process.env.PGPASSWORD || 'mapserver',
};

const GRID3_BASE = 'https://services3.arcgis.com/BU6Aadhn6tbBEdyk/arcgis/rest/services/NGA_Ward_Boundaries/FeatureServer/0/query';

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const stateFilter = (() => {
  const idx = args.indexOf('--state');
  return idx >= 0 ? args[idx + 1] : DEFAULT_STATE;
})();
const dryRun = args.includes('--dry-run');

function log(msg)  { console.log(`[INFO]    ${msg}`); }
function ok(msg)   { console.log(`[SUCCESS] ${msg}`); }
function warn(msg) { console.log(`[WARN]    ${msg}`); }

// ---------------------------------------------------------------------------
// HTTPS fetch helper
// ---------------------------------------------------------------------------
function fetchUrl(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode !== 200) {
          reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 300)}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(new Error(`JSON parse error: ${e.message}`));
        }
      });
      res.on('error', reject);
    }).on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Fetch all wards for a GRID3 statecode (handles ArcGIS pagination)
// ---------------------------------------------------------------------------
async function fetchGrid3Wards(statecode) {
  const allFeatures = [];
  let offset = 0;
  const pageSize = 1000;

  while (true) {
    const params = new URLSearchParams({
      where:             `statecode='${statecode}'`,
      outFields:         'wardname,wardcode,lgacode,statecode',
      f:                 'geojson',
      outSR:             '4326',
      resultRecordCount: String(pageSize),
      resultOffset:      String(offset),
    });

    const url = `${GRID3_BASE}?${params.toString()}`;
    if (offset === 0) {
      log(`Fetching GRID3 wards for statecode=${statecode}...`);
    }

    const geojson = await fetchUrl(url);
    const features = geojson.features || [];
    allFeatures.push(...features);

    if (features.length < pageSize) break;  // last page
    offset += pageSize;
    log(`  Paginating: fetched ${allFeatures.length} so far...`);
  }

  log(`  Total: ${allFeatures.length} ward features`);
  return allFeatures;
}

// ---------------------------------------------------------------------------
// Derive HDX-format ward pcodes from GRID3 lgacode field
// Sequence is per-LGA, reset to 001 for each LGA, sorted by wardname
// ---------------------------------------------------------------------------
function deriveWardPcodes(features) {
  // Group by lgacode
  const byLga = new Map();
  for (const feat of features) {
    const p = feat.properties || {};
    const lgacode = String(p.lgacode || '').trim();
    if (!lgacode) {
      warn(`  Skipping feature with missing lgacode: wardname=${p.wardname}`);
      continue;
    }
    if (!byLga.has(lgacode)) byLga.set(lgacode, []);
    byLga.get(lgacode).push(feat);
  }

  // For each LGA group: sort alphabetically by wardname, assign sequential pcode
  const result = [];
  const lgacodes = Array.from(byLga.keys()).sort();
  for (const lgacode of lgacodes) {
    const wards = byLga.get(lgacode);
    const lgaPcode = 'NG0' + lgacode;  // "NG0" + "18001" = "NG018001"

    wards.sort((a, b) => {
      const na = (a.properties.wardname || '').toLowerCase();
      const nb = (b.properties.wardname || '').toLowerCase();
      return na < nb ? -1 : na > nb ? 1 : 0;
    });

    wards.forEach((feat, i) => {
      const seq = String(i + 1).padStart(3, '0');
      result.push({
        feat,
        lgaPcode,
        wardPcode: lgaPcode + seq,
        wardName:  (feat.properties.wardname || '').trim(),
      });
    });
  }

  return result;
}

// ---------------------------------------------------------------------------
// Upsert ward features into adm_features
// ---------------------------------------------------------------------------
async function importWards(client, wards) {
  let inserted = 0;
  let skipped  = 0;

  for (const { feat, lgaPcode, wardPcode, wardName } of wards) {
    if (!wardName) {
      warn(`  Skipping ward with empty name: pcode=${wardPcode}`);
      skipped++;
      continue;
    }
    if (!feat.geometry) {
      warn(`  Skipping ward with null geometry: pcode=${wardPcode} name=${wardName}`);
      skipped++;
      continue;
    }

    if (dryRun) {
      log(`  [DRY-RUN] ${wardPcode}  "${wardName}"  (parent: ${lgaPcode})`);
      inserted++;
      continue;
    }

    const geomJson = JSON.stringify(feat.geometry);
    await client.query(`
      INSERT INTO adm_features
        (country_code, adm_level, pcode, name, parent_pcode, geom, level_label)
      VALUES (
        'NG', 3, $1, $2, $3,
        ST_Multi(ST_GeomFromGeoJSON($4)),
        'Ward'
      )
      ON CONFLICT (pcode) DO UPDATE SET
        name         = EXCLUDED.name,
        parent_pcode = EXCLUDED.parent_pcode,
        geom         = EXCLUDED.geom,
        level_label  = EXCLUDED.level_label
    `, [wardPcode, wardName, lgaPcode, geomJson]);

    inserted++;
  }

  return { inserted, skipped };
}

// ---------------------------------------------------------------------------
// Compute area_sqkm and centers via PostGIS for newly imported wards
// ---------------------------------------------------------------------------
async function computeGeometry(client, statePcode) {
  log('Computing area_sqkm and centers via PostGIS...');
  const res = await client.query(`
    UPDATE adm_features SET
      area_sqkm  = ST_Area(geom::geography) / 1e6,
      center_lat = ST_Y(ST_Centroid(geom)),
      center_lon = ST_X(ST_Centroid(geom))
    WHERE (area_sqkm IS NULL OR center_lat IS NULL)
      AND country_code = 'NG'
      AND adm_level = 3
      AND level_label = 'Ward'
      AND parent_pcode LIKE $1
  `, [statePcode + '%']);
  if (res.rowCount > 0) {
    ok(`  PostGIS computed area/center for ${res.rowCount} wards`);
  }
}

// ---------------------------------------------------------------------------
// Update tenant_scope for the state's tenant
// ---------------------------------------------------------------------------
async function updateTenantScope(client, tenantId, statePcode) {
  log(`Updating tenant_scope for tenant ${tenantId} (${statePcode})...`);
  const res = await client.query(`
    INSERT INTO tenant_scope (tenant_id, pcode)
    SELECT $1, pcode FROM adm_features
    WHERE country_code = 'NG'
      AND adm_level = 3
      AND level_label = 'Ward'
      AND parent_pcode LIKE $2
    ON CONFLICT DO NOTHING
    RETURNING pcode
  `, [tenantId, statePcode + '%']);
  ok(`  +${res.rowCount} ward pcodes added to tenant_scope`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('');
  console.log('================================================');
  console.log('  GRID3 Ward Boundaries -> PostgreSQL import');
  console.log(`  State: ${stateFilter}`);
  if (dryRun) console.log('  DRY RUN — no changes will be written');
  console.log('================================================');
  console.log('');

  const statecode = STATE_CODE_MAP[stateFilter];
  if (!statecode) {
    console.error(`[ERROR] Unknown state pcode: ${stateFilter}`);
    console.error(`        Supported states: ${Object.keys(STATE_CODE_MAP).join(', ')}`);
    process.exit(1);
  }

  const tenantId = STATE_TENANT_MAP[stateFilter];
  if (!tenantId && !dryRun) {
    console.error(`[ERROR] No tenant mapping for state: ${stateFilter}`);
    process.exit(1);
  }

  // Step 1: Fetch from GRID3
  const features = await fetchGrid3Wards(statecode);
  if (features.length === 0) {
    console.error('[ERROR] No ward features returned from GRID3 — check URL or statecode');
    process.exit(1);
  }

  // Step 2: Derive ward pcodes
  const wards = deriveWardPcodes(features);
  const lgaCount = new Set(wards.map((w) => w.lgaPcode)).size;
  log(`Derived ${wards.length} ward pcodes across ${lgaCount} LGAs`);

  if (dryRun) {
    console.log('');
    log('Sample (first 10):');
    for (const w of wards.slice(0, 10)) {
      log(`  ${w.wardPcode}  "${w.wardName}"  (parent: ${w.lgaPcode})`);
    }
    console.log('\n[DRY-RUN] Done — no database changes made.\n');
    return;
  }

  // Step 3: Import into PostgreSQL
  const client = new Client(PG_CONFIG);
  try {
    await client.connect();
    ok(`Connected to ${PG_CONFIG.host}:${PG_CONFIG.port}/${PG_CONFIG.database}`);

    await client.query('BEGIN');

    const { inserted, skipped } = await importWards(client, wards);
    ok(`Imported ${inserted} wards (${skipped} skipped)`);

    await computeGeometry(client, stateFilter);
    await updateTenantScope(client, tenantId, stateFilter);

    await client.query('COMMIT');

    log('Running VACUUM ANALYZE...');
    await client.query('VACUUM ANALYZE adm_features');
    await client.query('VACUUM ANALYZE tenant_scope');

    console.log('');
    console.log('================================================');
    console.log('  Done. Verify with:');
    console.log('  SELECT adm_level, level_label, COUNT(*)');
    console.log(`  FROM adm_features WHERE country_code='NG'`);
    console.log(`    AND pcode LIKE '${stateFilter}%'`);
    console.log('  GROUP BY 1,2 ORDER BY 1;');
    console.log('');
    console.log('  Restart nginx to clear hierarchy cache:');
    console.log('  sudo docker restart tileserver_nginx_1');
    console.log('================================================');
    console.log('');

  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('[ERROR]', err.message);
    process.exit(1);
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error('[ERROR]', err.message);
  process.exit(1);
});
