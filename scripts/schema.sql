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
    center_lon   FLOAT
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
    parent_pcode       VARCHAR(30)  NOT NULL,    -- state pcode this zone belongs to
    constituent_pcodes TEXT[]       NOT NULL,    -- LGA pcodes grouped into this zone
    geom               GEOMETRY(MULTIPOLYGON, 4326),  -- ST_Union of constituent LGAs, pre-computed
    created_at         TIMESTAMPTZ  DEFAULT NOW(),
    updated_at         TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX zones_geom_idx   ON zones USING GIST(geom);
CREATE INDEX zones_tenant_idx ON zones(tenant_id);
CREATE INDEX zones_parent_idx ON zones(parent_pcode);
CREATE INDEX zones_pcode_idx  ON zones(zone_pcode);
