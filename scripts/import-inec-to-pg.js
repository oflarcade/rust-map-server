#!/usr/bin/env node
// import-inec-to-pg.js
// Imports Nigeria INEC electoral boundary GeoJSON files into adm_features.
//
// Expected input files (from download-inec.ps1):
//   data/inec/nigeria_senatorial.geojson  -> adm_level=3, level_label="Senatorial District"
//   data/inec/nigeria_constituencies.geojson -> adm_level=4, level_label="Federal Constituency"
//
// Also handles emirate data if present:
//   data/inec/nigeria_emirates.geojson    -> adm_level=5, level_label="Emirate"  (optional)
//
// After import, adds new pcodes to tenant_scope for affected tenants.
//
// Usage:
//   node scripts/import-inec-to-pg.js
//   node scripts/import-inec-to-pg.js --state NG018   # Jigawa only
//   node scripts/import-inec-to-pg.js --dry-run

'use strict';

const path = require('path');
const fs   = require('fs');
const { Client } = require('pg');

const INEC_DIR = path.join(__dirname, '../data/inec');

const PG_CONFIG = {
  host:     process.env.PGHOST     || 'localhost',
  port:     parseInt(process.env.PGPORT || '5432'),
  database: process.env.PGDATABASE || 'mapserver',
  user:     process.env.PGUSER     || 'mapserver',
  password: process.env.PGPASSWORD || 'mapserver',
};

// Tenants that operate in Nigeria
const NIGERIA_TENANTS = [3, 9, 11, 14, 16, 18];

// Nigerian state pcodes per state tenant (same as import-hdx-to-pg.js)
const NIGERIA_STATE_SCOPE = {
  3:  ['NG025', 'NG030'],  // Lagos + Osun
  9:  ['NG012'],           // Edo
  11: ['NG025'],           // Lagos
  14: ['NG024'],           // Kwara
  16: ['NG006'],           // Bayelsa
  18: ['NG018'],           // Jigawa
};

// Files to import: { file, adm_level, level_label, pcode_field, name_field, parent_pcode_field }
// Field names are guesses based on common HDX INEC GeoJSON formats — adjust if actual fields differ.
const INEC_FILES = [
  {
    file:               'nigeria_senatorial.geojson',
    adm_level:          3,
    level_label:        'Senatorial District',
    pcode_field:        'sen_pcode',
    alt_pcode_fields:   ['pcode', 'SEN_PCODE', 'adm3_pcode'],
    name_field:         'sen_name',
    alt_name_fields:    ['name', 'SEN_NAME', 'adm3_name', 'NAME'],
    parent_pcode_field: 'adm1_pcode',
    alt_parent_fields:  ['state_pcode', 'ADM1_PCODE', 'parent_pcode'],
  },
  {
    file:               'nigeria_constituencies.geojson',
    adm_level:          4,
    level_label:        'Federal Constituency',
    pcode_field:        'con_pcode',
    alt_pcode_fields:   ['pcode', 'CON_PCODE', 'adm4_pcode'],
    name_field:         'con_name',
    alt_name_fields:    ['name', 'CON_NAME', 'adm4_name', 'NAME'],
    parent_pcode_field: 'sen_pcode',
    alt_parent_fields:  ['adm3_pcode', 'SEN_PCODE', 'parent_pcode'],
  },
  {
    file:               'nigeria_emirates.geojson',   // optional
    adm_level:          5,
    level_label:        'Emirate',
    pcode_field:        'emir_pcode',
    alt_pcode_fields:   ['pcode', 'EMIR_PCODE', 'adm5_pcode'],
    name_field:         'emir_name',
    alt_name_fields:    ['name', 'EMIR_NAME', 'adm5_name', 'NAME'],
    parent_pcode_field: 'adm1_pcode',
    alt_parent_fields:  ['state_pcode', 'ADM1_PCODE', 'parent_pcode'],
    optional:           true,
  },
];

const args = process.argv.slice(2);
const stateFilter = (() => {
  const idx = args.indexOf('--state');
  return idx >= 0 ? args[idx + 1] : null;
})();
const dryRun = args.includes('--dry-run');

function log(msg)  { console.log(`[INFO]    ${msg}`); }
function ok(msg)   { console.log(`[SUCCESS] ${msg}`); }
function warn(msg) { console.log(`[WARN]    ${msg}`); }

// ---------------------------------------------------------------------------
// Resolve field value using primary + fallback field names
// ---------------------------------------------------------------------------
function resolveField(props, primary, alts) {
  if (props[primary] !== undefined && props[primary] !== null) return props[primary];
  for (const alt of (alts || [])) {
    if (props[alt] !== undefined && props[alt] !== null) return props[alt];
  }
  return null;
}

// ---------------------------------------------------------------------------
// Import a single GeoJSON file into adm_features
// ---------------------------------------------------------------------------
async function importFile(client, spec) {
  const filepath = path.join(INEC_DIR, spec.file);

  if (!fs.existsSync(filepath)) {
    if (spec.optional) {
      warn(`  ${spec.file} not found — skipping (optional)`);
      return 0;
    }
    throw new Error(`Required file not found: ${filepath}`);
  }

  log(`  Importing ${spec.file} (adm${spec.adm_level} ${spec.level_label})...`);

  const geojson   = JSON.parse(fs.readFileSync(filepath, 'utf8'));
  const features  = geojson.features || [];
  let inserted    = 0;
  let skipped     = 0;

  for (const feat of features) {
    const p = feat.properties || {};

    const pcode       = resolveField(p, spec.pcode_field, spec.alt_pcode_fields);
    const name        = resolveField(p, spec.name_field,  spec.alt_name_fields);
    const parentPcode = resolveField(p, spec.parent_pcode_field, spec.alt_parent_fields);

    if (!pcode || !name) {
      warn(`    Skipping feature: missing pcode or name (pcode=${pcode}, name=${name})`);
      skipped++;
      continue;
    }

    // Apply state filter if specified
    if (stateFilter && parentPcode && !parentPcode.startsWith(stateFilter)) {
      skipped++;
      continue;
    }

    if (dryRun) {
      log(`    [DRY-RUN] Would insert: pcode=${pcode} name=${name} parent=${parentPcode}`);
      inserted++;
      continue;
    }

    const geomJson = JSON.stringify(feat.geometry);

    await client.query(`
      INSERT INTO adm_features
        (country_code, adm_level, pcode, name, parent_pcode, geom, level_label)
      VALUES (
        'NG', $1, $2, $3, $4,
        ST_Multi(ST_GeomFromGeoJSON($5)),
        $6
      )
      ON CONFLICT (pcode) DO UPDATE SET
        name         = EXCLUDED.name,
        parent_pcode = EXCLUDED.parent_pcode,
        geom         = EXCLUDED.geom,
        level_label  = EXCLUDED.level_label
    `, [spec.adm_level, pcode, name, parentPcode, geomJson, spec.level_label]);

    inserted++;
  }

  ok(`    ${inserted} features inserted/updated, ${skipped} skipped`);
  return inserted;
}

// ---------------------------------------------------------------------------
// Populate tenant_scope for Nigerian tenants with new adm3+ pcodes
// ---------------------------------------------------------------------------
async function updateTenantScope(client) {
  log('Updating tenant_scope for Nigerian tenants...');

  for (const tenantId of NIGERIA_TENANTS) {
    const statePcodes = NIGERIA_STATE_SCOPE[tenantId];

    if (statePcodes) {
      // State tenant — scope to adm3+ under their assigned states
      for (const statePcode of statePcodes) {
        if (stateFilter && statePcode !== stateFilter) continue;

        const res = await client.query(`
          INSERT INTO tenant_scope(tenant_id, pcode)
          SELECT $1, pcode FROM adm_features
          WHERE country_code = 'NG' AND adm_level >= 3
            AND (
              pcode LIKE $2 OR
              parent_pcode LIKE $2 OR
              parent_pcode IN (
                SELECT pcode FROM adm_features
                WHERE country_code = 'NG' AND pcode LIKE $2
              )
            )
          ON CONFLICT DO NOTHING
          RETURNING pcode
        `, [tenantId, statePcode + '%']);

        if (res.rowCount > 0) {
          log(`    Tenant ${tenantId} (${statePcode}): +${res.rowCount} adm3+ pcodes`);
        }
      }
    } else {
      // Full-country tenant (tenant 3 covers NG full) — scope to all NG adm3+
      const res = await client.query(`
        INSERT INTO tenant_scope(tenant_id, pcode)
        SELECT $1, pcode FROM adm_features
        WHERE country_code = 'NG' AND adm_level >= 3
        ON CONFLICT DO NOTHING
        RETURNING pcode
      `, [tenantId]);

      if (res.rowCount > 0) {
        log(`    Tenant ${tenantId} (full NG): +${res.rowCount} adm3+ pcodes`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Compute missing area/center
// ---------------------------------------------------------------------------
async function computeMissingGeometry(client) {
  log('Computing missing area_sqkm and centers via PostGIS...');
  const updated = await client.query(`
    UPDATE adm_features SET
      area_sqkm  = ST_Area(geom::geography) / 1e6,
      center_lat = ST_Y(ST_Centroid(geom)),
      center_lon = ST_X(ST_Centroid(geom))
    WHERE (area_sqkm IS NULL OR center_lat IS NULL)
      AND country_code = 'NG'
      AND adm_level >= 3
  `);
  if (updated.rowCount > 0) {
    ok(`  PostGIS computed area/center for ${updated.rowCount} features`);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('');
  console.log('================================================');
  console.log('  INEC Electoral Boundaries -> PostgreSQL import');
  if (stateFilter) console.log(`  State filter: ${stateFilter}`);
  if (dryRun) console.log('  DRY RUN — no changes will be written');
  console.log('================================================');
  console.log('');

  if (!fs.existsSync(INEC_DIR)) {
    console.error(`[ERROR] INEC data directory not found: ${INEC_DIR}`);
    console.error('        Run scripts/ps1/download-inec.ps1 first');
    process.exit(1);
  }

  const client = new Client(PG_CONFIG);

  try {
    await client.connect();
    ok(`Connected to ${PG_CONFIG.host}:${PG_CONFIG.port}/${PG_CONFIG.database}`);

    if (!dryRun) await client.query('BEGIN');

    let totalInserted = 0;
    for (const spec of INEC_FILES) {
      totalInserted += await importFile(client, spec);
    }

    if (!dryRun) {
      await computeMissingGeometry(client);
      await updateTenantScope(client);
      await client.query('COMMIT');

      log('Running VACUUM ANALYZE...');
      await client.query('VACUUM ANALYZE adm_features');
      await client.query('VACUUM ANALYZE tenant_scope');
    }

    ok(`Total features processed: ${totalInserted}`);

    console.log('');
    console.log('================================================');
    console.log('  Verify with:');
    console.log('  SELECT adm_level, level_label, COUNT(*)');
    console.log('  FROM adm_features WHERE country_code=\'NG\'');
    console.log('  GROUP BY 1,2 ORDER BY 1;');
    console.log('================================================');
    console.log('');

  } catch (err) {
    if (!dryRun) await client.query('ROLLBACK').catch(() => {});
    console.error('[ERROR]', err.message);
    process.exit(1);
  } finally {
    await client.end();
  }
}

main();
