-- schema.sql
-- PostGIS schema for dynamic tenant hierarchy + zone management.
-- Auto-executed by postgres container on first boot via docker-entrypoint-initdb.d/

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------------
-- tenants
-- ---------------------------------------------------------------------------
CREATE TABLE tenants (
    tenant_id    INTEGER      PRIMARY KEY,
    country_code VARCHAR(10)  NOT NULL,
    country_name VARCHAR(255),
    tile_source  VARCHAR(255),   -- Martin source name (e.g. 'nigeria-lagos')
    hdx_prefix   VARCHAR(100)    -- 'nigeria', 'kenya', '' if no HDX data
);

-- ---------------------------------------------------------------------------
-- adm_features  (all HDX admin levels for all countries, shared)
-- ---------------------------------------------------------------------------
-- geom uses generic GEOMETRY type because HDX files mix Polygon + MultiPolygon.
-- Import script calls ST_Multi() to normalise to MultiPolygon before insert.
CREATE TABLE adm_features (
    id           SERIAL       PRIMARY KEY,
    country_code VARCHAR(10)  NOT NULL,
    adm_level    SMALLINT     NOT NULL,  -- 1 = state/province, 2 = LGA/district, 3+ = sub-district
    pcode        VARCHAR(30)  NOT NULL UNIQUE,
    name         VARCHAR(255) NOT NULL,
    parent_pcode VARCHAR(30),
    geom         GEOMETRY(MULTIPOLYGON, 4326) NOT NULL,
    area_sqkm    FLOAT,
    center_lat   FLOAT,
    center_lon   FLOAT,
    level_label  VARCHAR(100)  -- human-readable type name for adm3+, e.g. "Ward", "Senatorial District"
);

CREATE INDEX adm_features_geom_idx    ON adm_features USING GIST(geom);
CREATE INDEX adm_features_country_lvl ON adm_features(country_code, adm_level);
CREATE INDEX adm_features_parent      ON adm_features(parent_pcode);
CREATE INDEX adm_features_name        ON adm_features(LOWER(name));

-- ---------------------------------------------------------------------------
-- tenant_scope  (which pcodes each tenant operates on)
-- ---------------------------------------------------------------------------
-- Always fully populated. No rows means no access (not "full country").
-- Country tenants: all adm1 + adm2 pcodes for their country.
-- State tenants:   all adm2 pcodes for their assigned state(s).
CREATE TABLE tenant_scope (
    tenant_id INTEGER     NOT NULL REFERENCES tenants(tenant_id),
    pcode     VARCHAR(30) NOT NULL REFERENCES adm_features(pcode),
    PRIMARY KEY (tenant_id, pcode)
);

CREATE INDEX tenant_scope_tenant ON tenant_scope(tenant_id);
CREATE INDEX tenant_scope_pcode  ON tenant_scope(pcode);

-- ---------------------------------------------------------------------------
-- zones  (custom operator-defined groupings of LGAs per tenant)
-- ---------------------------------------------------------------------------
CREATE TABLE zones (
    zone_id            SERIAL       PRIMARY KEY,
    tenant_id          INTEGER      NOT NULL REFERENCES tenants(tenant_id),
    zone_pcode         VARCHAR(40)  NOT NULL UNIQUE,
    zone_name          VARCHAR(255) NOT NULL,
    color              VARCHAR(7),               -- hex e.g. '#FF5733'
    parent_pcode       VARCHAR(30)  NOT NULL,    -- state pcode OR parent zone_pcode
    constituent_pcodes TEXT[]       NOT NULL,    -- adm_features pcodes OR child zone pcodes
    geom               GEOMETRY(MULTIPOLYGON, 4326),  -- ST_Union of constituents, pre-computed
    zone_type_label    VARCHAR(100),             -- human-readable zone type, e.g. "Operational Zone"
    zone_level         SMALLINT     NOT NULL DEFAULT 1,  -- nesting depth (1 = directly under state)
    children_type      VARCHAR(4)   NOT NULL DEFAULT 'lga', -- 'lga' = constituent_pcodes are adm_features, 'zone' = child zones
    created_at         TIMESTAMPTZ  DEFAULT NOW(),
    updated_at         TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX zones_geom_idx    ON zones USING GIST(geom);
CREATE INDEX zones_tenant_idx  ON zones(tenant_id);
CREATE INDEX zones_parent_idx  ON zones(parent_pcode);
CREATE INDEX zones_pcode_idx   ON zones(zone_pcode);
CREATE INDEX zones_level_idx   ON zones(tenant_id, zone_level);

-- ---------------------------------------------------------------------------
-- Migration statements — safe to run on existing installations (idempotent)
-- These are no-ops on fresh installs because the columns already exist above.
-- ---------------------------------------------------------------------------
ALTER TABLE adm_features ADD COLUMN IF NOT EXISTS level_label VARCHAR(100);
ALTER TABLE zones ADD COLUMN IF NOT EXISTS zone_type_label VARCHAR(100);
ALTER TABLE zones ADD COLUMN IF NOT EXISTS zone_level    SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE zones ADD COLUMN IF NOT EXISTS children_type VARCHAR(4) NOT NULL DEFAULT 'lga';
ALTER TABLE zones ADD COLUMN IF NOT EXISTS updated_by    VARCHAR(255);
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS boundary_source VARCHAR(255);

-- ---------------------------------------------------------------------------
-- geo_hierarchy_levels  (per-tenant custom hierarchy level definitions)
-- ---------------------------------------------------------------------------
-- level_label should match adm_features.level_label for the tenant's country_code (HDX / INEC / OCHA);
-- UI loads DISTINCT options via GET /admin/geo-hierarchy/level-labels (dynamic per tenant’s country).
CREATE TABLE IF NOT EXISTS geo_hierarchy_levels (
    id          SERIAL PRIMARY KEY,
    tenant_id   INTEGER NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    level_order SMALLINT NOT NULL,
    level_label VARCHAR(100) NOT NULL,
    level_code  VARCHAR(10)  NOT NULL,
    UNIQUE(tenant_id, level_order),
    UNIQUE(tenant_id, level_code)
);

-- ---------------------------------------------------------------------------
-- geo_hierarchy_nodes  (the hierarchy tree nodes)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geo_hierarchy_nodes (
    id                 SERIAL PRIMARY KEY,
    tenant_id          INTEGER  NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    parent_id          INTEGER  REFERENCES geo_hierarchy_nodes(id) ON DELETE CASCADE,
    state_pcode        VARCHAR(30) NOT NULL,
    level_id           INTEGER  NOT NULL REFERENCES geo_hierarchy_levels(id),
    pcode              VARCHAR(80) NOT NULL UNIQUE,
    name               VARCHAR(200) NOT NULL,
    color              VARCHAR(7),
    constituent_pcodes TEXT[],
    geom               GEOMETRY(MULTIPOLYGON, 4326),
    area_sqkm          NUMERIC,
    center_lat         NUMERIC,
    center_lon         NUMERIC,
    created_at         TIMESTAMPTZ DEFAULT NOW(),
    updated_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ghn_tenant_idx ON geo_hierarchy_nodes(tenant_id);
CREATE INDEX IF NOT EXISTS ghn_parent_idx ON geo_hierarchy_nodes(parent_id);
CREATE INDEX IF NOT EXISTS ghn_state_idx  ON geo_hierarchy_nodes(tenant_id, state_pcode);
CREATE INDEX IF NOT EXISTS ghn_pcode_idx  ON geo_hierarchy_nodes(pcode);
CREATE INDEX IF NOT EXISTS ghn_geom_idx   ON geo_hierarchy_nodes USING GIST(geom);

-- ---------------------------------------------------------------------------
-- tenant_cache  (persistent L2 cache — survives nginx/docker restarts)
-- ---------------------------------------------------------------------------
-- Stores pre-computed JSON payloads per tenant+key so that ngx.shared cold
-- misses (after restart) fall back to a cheap SELECT rather than re-running
-- the full multi-join + Lua tree-build.  Written on first cache miss; cleared
-- on any admin write that changes hierarchy or geojson data.
--
-- cache_key values:
--   'hierarchy'     → /boundaries/hierarchy  (main branch, geo_hierarchy_nodes tree)
--   'hierarchy_raw' → /boundaries/hierarchy?raw=1  (raw adm_features tree)
--   'geojson'       → /boundaries/geojson
CREATE TABLE IF NOT EXISTS tenant_cache (
    tenant_id  INTEGER NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    cache_key  TEXT    NOT NULL,
    payload    TEXT    NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (tenant_id, cache_key)
);
