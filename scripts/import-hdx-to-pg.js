#!/usr/bin/env node
// import-hdx-to-pg.js
// Imports all HDX GeoJSON admin boundary data into PostgreSQL.
//
// Run once after the postgres container is healthy:
//   cd scripts && npm install
//   node scripts/import-hdx-to-pg.js
//
// Idempotent: uses INSERT ... ON CONFLICT DO UPDATE.

'use strict';

const path = require('path');
const fs   = require('fs');
const { Client } = require('pg');

const HDX_DIR = path.join(__dirname, '../data/hdx');

const PG_CONFIG = {
  host:     process.env.PGHOST     || 'localhost',
  port:     parseInt(process.env.PGPORT || '5432'),
  database: process.env.PGDATABASE || 'mapserver',
  user:     process.env.PGUSER     || 'mapserver',
  password: process.env.PGPASSWORD || 'mapserver',
};

// ---------------------------------------------------------------------------
// Tenant definitions — mirrors nginx-tenant-proxy.conf static maps
// ---------------------------------------------------------------------------
const TENANTS = [
  { tenant_id: 1,  country_code: 'KE', country_name: 'Kenya',                  tile_source: 'kenya-detailed',                       hdx_prefix: 'kenya' },
  { tenant_id: 2,  country_code: 'UG', country_name: 'Uganda',                 tile_source: 'uganda-detailed',                      hdx_prefix: 'uganda' },
  { tenant_id: 3,  country_code: 'NG', country_name: 'Nigeria',                tile_source: 'nigeria-lagos-osun',                   hdx_prefix: 'nigeria' },
  { tenant_id: 4,  country_code: 'LR', country_name: 'Liberia',                tile_source: 'liberia-detailed',                     hdx_prefix: 'liberia' },
  { tenant_id: 5,  country_code: 'IN', country_name: 'India',                  tile_source: 'india-andhrapradesh',                  hdx_prefix: '' },
  { tenant_id: 9,  country_code: 'NG', country_name: 'Nigeria',                tile_source: 'nigeria-edo',                          hdx_prefix: 'nigeria' },
  { tenant_id: 11, country_code: 'NG', country_name: 'Nigeria',                tile_source: 'nigeria-lagos',                        hdx_prefix: 'nigeria' },
  { tenant_id: 12, country_code: 'RW', country_name: 'Rwanda',                 tile_source: 'rwanda-detailed',                      hdx_prefix: '' },
  { tenant_id: 14, country_code: 'NG', country_name: 'Nigeria',                tile_source: 'nigeria-kwara',                        hdx_prefix: 'nigeria' },
  { tenant_id: 15, country_code: 'IN', country_name: 'India',                  tile_source: 'india-manipur',                        hdx_prefix: '' },
  { tenant_id: 16, country_code: 'NG', country_name: 'Nigeria',                tile_source: 'nigeria-bayelsa',                      hdx_prefix: 'nigeria' },
  { tenant_id: 17, country_code: 'CF', country_name: 'Central African Republic', tile_source: 'central-african-republic-detailed', hdx_prefix: 'central-african-republic' },
  { tenant_id: 18, country_code: 'NG', country_name: 'Nigeria',                tile_source: 'nigeria-jigawa',                       hdx_prefix: 'nigeria' },
];

// Nigerian state pcodes for state tenants (from HDX Nigeria adm1)
// Tenant 3 = Lagos + Osun (combined tile), Tenant 9 = Edo, etc.
const NIGERIA_STATE_SCOPE = {
  3:  ['NG025', 'NG030'],  // Lagos + Osun
  9:  ['NG012'],           // Edo
  11: ['NG025'],           // Lagos
  14: ['NG024'],           // Kwara
  16: ['NG006'],           // Bayelsa
  18: ['NG018'],           // Jigawa
};

// HDX country prefix -> ISO2 country code (for grouping files)
const HDX_PREFIX_TO_ISO2 = {
  'nigeria':                  'NG',
  'kenya':                    'KE',
  'uganda':                   'UG',
  'liberia':                  'LR',
  'central-african-republic': 'CF',
};

// All HDX prefixes that have data
const HDX_PREFIXES = Object.keys(HDX_PREFIX_TO_ISO2);

function log(msg)  { console.log(`[INFO]    ${msg}`); }
function ok(msg)   { console.log(`[SUCCESS] ${msg}`); }
function warn(msg) { console.log(`[WARN]    ${msg}`); }

// ---------------------------------------------------------------------------
// Step 1: Insert tenants
// ---------------------------------------------------------------------------
async function insertTenants(client) {
  log('Inserting tenants...');
  for (const t of TENANTS) {
    await client.query(`
      INSERT INTO tenants(tenant_id, country_code, country_name, tile_source, hdx_prefix)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (tenant_id) DO UPDATE SET
        country_code = EXCLUDED.country_code,
        country_name = EXCLUDED.country_name,
        tile_source  = EXCLUDED.tile_source,
        hdx_prefix   = EXCLUDED.hdx_prefix
    `, [t.tenant_id, t.country_code, t.country_name, t.tile_source, t.hdx_prefix]);
  }
  ok(`Inserted ${TENANTS.length} tenants`);
}

// ---------------------------------------------------------------------------
// Step 2: Import adm_features from HDX GeoJSON files
// ---------------------------------------------------------------------------
async function importAdmFeatures(client) {
  log('Importing adm_features from HDX GeoJSON...');
  let totalInserted = 0;

  for (const prefix of HDX_PREFIXES) {
    const countryCode = HDX_PREFIX_TO_ISO2[prefix];

    // Find all admN files for this prefix
    const files = fs.readdirSync(HDX_DIR)
      .filter(f => f.startsWith(`${prefix}_adm`) && f.endsWith('.geojson'))
      .sort();

    if (files.length === 0) {
      warn(`No HDX files found for prefix '${prefix}' in ${HDX_DIR}`);
      continue;
    }

    for (const filename of files) {
      const levelMatch = filename.match(/_adm(\d+)\.geojson$/);
      if (!levelMatch) continue;
      const admLevel = parseInt(levelMatch[1]);

      const filepath = path.join(HDX_DIR, filename);
      log(`  ${filename} (ADM${admLevel}, ${countryCode})...`);

      const geojson = JSON.parse(fs.readFileSync(filepath, 'utf8'));
      const features = geojson.features || [];

      let inserted = 0;
      for (const feat of features) {
        const p = feat.properties || {};

        const pcode       = p[`adm${admLevel}_pcode`];
        const name        = p[`adm${admLevel}_name`];
        const parentPcode = admLevel > 1 ? (p[`adm${admLevel - 1}_pcode`] || null) : null;

        if (!pcode || !name) {
          warn(`    Skipping feature missing pcode/name in ${filename}`);
          continue;
        }

        // HDX files often have pre-computed area/center — use if available
        const areaSqkm  = p.area_sqkm  || null;
        const centerLat = p.center_lat || null;
        const centerLon = p.center_lon || null;

        const geomJson = JSON.stringify(feat.geometry);

        await client.query(`
          INSERT INTO adm_features
            (country_code, adm_level, pcode, name, parent_pcode, geom, area_sqkm, center_lat, center_lon)
          VALUES (
            $1, $2, $3, $4, $5,
            ST_Multi(ST_GeomFromGeoJSON($6)),
            $7, $8, $9
          )
          ON CONFLICT (pcode) DO UPDATE SET
            country_code = EXCLUDED.country_code,
            adm_level    = EXCLUDED.adm_level,
            name         = EXCLUDED.name,
            parent_pcode = EXCLUDED.parent_pcode,
            geom         = EXCLUDED.geom,
            area_sqkm    = EXCLUDED.area_sqkm,
            center_lat   = EXCLUDED.center_lat,
            center_lon   = EXCLUDED.center_lon
        `, [countryCode, admLevel, pcode, name, parentPcode, geomJson, areaSqkm, centerLat, centerLon]);

        inserted++;
      }
      ok(`    ${inserted} features inserted (${filename})`);
      totalInserted += inserted;
    }
  }

  // Fill in any missing area/center via PostGIS (catches features without pre-computed values)
  log('Computing missing area_sqkm and centers via PostGIS...');
  const updated = await client.query(`
    UPDATE adm_features SET
      area_sqkm  = ST_Area(geom::geography) / 1e6,
      center_lat = ST_Y(ST_Centroid(geom)),
      center_lon = ST_X(ST_Centroid(geom))
    WHERE area_sqkm IS NULL OR center_lat IS NULL
  `);
  if (updated.rowCount > 0) {
    ok(`  PostGIS computed area/center for ${updated.rowCount} features`);
  }

  ok(`Total adm_features inserted/updated: ${totalInserted}`);
}

// ---------------------------------------------------------------------------
// Step 3: Populate tenant_scope
// ---------------------------------------------------------------------------
async function populateTenantScope(client) {
  log('Populating tenant_scope...');

  // Clear existing scope (idempotent re-run)
  await client.query('DELETE FROM tenant_scope');

  for (const tenant of TENANTS) {
    const { tenant_id, country_code, hdx_prefix } = tenant;

    if (!hdx_prefix) {
      // Rwanda, India — no HDX data, no scope to populate
      warn(`  Tenant ${tenant_id} (${tenant.country_name}): no HDX data — skipping scope`);
      continue;
    }

    if (NIGERIA_STATE_SCOPE[tenant_id]) {
      // Nigerian state tenant — scope to specific state(s) at adm2 level
      const statePcodes = NIGERIA_STATE_SCOPE[tenant_id];
      log(`  Tenant ${tenant_id}: Nigeria state tenant, states ${statePcodes.join(', ')}`);

      for (const statePcode of statePcodes) {
        // Insert the state itself (adm1)
        await client.query(`
          INSERT INTO tenant_scope(tenant_id, pcode)
          SELECT $1, pcode FROM adm_features
          WHERE pcode = $2
          ON CONFLICT DO NOTHING
        `, [tenant_id, statePcode]);

        // Insert all LGAs (adm2) in that state
        const res = await client.query(`
          INSERT INTO tenant_scope(tenant_id, pcode)
          SELECT $1, pcode FROM adm_features
          WHERE country_code = $2 AND adm_level = 2 AND parent_pcode = $3
          ON CONFLICT DO NOTHING
          RETURNING pcode
        `, [tenant_id, country_code, statePcode]);
        log(`    State ${statePcode}: ${res.rowCount} LGAs added`);
      }

    } else {
      // Full-country tenant — scope to all adm levels for this country
      log(`  Tenant ${tenant_id}: full country (${country_code})`);
      const res = await client.query(`
        INSERT INTO tenant_scope(tenant_id, pcode)
        SELECT $1, pcode FROM adm_features
        WHERE country_code = $2
        ON CONFLICT DO NOTHING
        RETURNING pcode
      `, [tenant_id, country_code]);
      log(`    ${res.rowCount} features added to scope`);
    }
  }

  const total = await client.query('SELECT COUNT(*) FROM tenant_scope');
  ok(`tenant_scope total rows: ${total.rows[0].count}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('');
  console.log('================================================');
  console.log('  HDX -> PostgreSQL import');
  console.log('================================================');
  console.log('');

  const client = new Client(PG_CONFIG);

  try {
    await client.connect();
    ok(`Connected to ${PG_CONFIG.host}:${PG_CONFIG.port}/${PG_CONFIG.database}`);

    await client.query('BEGIN');

    await insertTenants(client);
    await importAdmFeatures(client);
    await populateTenantScope(client);

    await client.query('COMMIT');

    // VACUUM after large import
    log('Running VACUUM ANALYZE...');
    await client.query('VACUUM ANALYZE adm_features');
    await client.query('VACUUM ANALYZE tenant_scope');
    ok('Done');

    console.log('');
    console.log('================================================');
    console.log('  Import complete. Verify with:');
    console.log('  SELECT country_code, adm_level, COUNT(*)');
    console.log('  FROM adm_features GROUP BY 1,2 ORDER BY 1,2;');
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

main();
