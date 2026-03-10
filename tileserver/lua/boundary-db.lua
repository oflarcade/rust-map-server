-- boundary-db.lua
-- All PostGIS queries for boundary endpoints.
-- Called by serve-geojson, serve-hierarchy, search-boundaries, region-lookup.

local pg = require("pg-pool")

local M = {}

-- ---------------------------------------------------------------------------
-- get_geojson(tenant_id)
-- Returns a list of GeoJSON feature rows for the tenant.
-- Includes: zones (pre-computed union), parent states, ungrouped LGAs.
-- ---------------------------------------------------------------------------
function M.get_geojson(tenant_id)
    local sql = [[
        -- Zones for this tenant (pre-computed ST_Union geometry)
        SELECT
            ST_AsGeoJSON(z.geom) AS geometry,
            z.zone_pcode         AS pcode,
            z.zone_name          AS name,
            'zone'               AS feature_type,
            z.parent_pcode,
            z.color,
            array_to_string(z.constituent_pcodes, ',') AS constituent_pcodes
        FROM zones z
        WHERE z.tenant_id = $1

        UNION ALL

        -- States: derived from the parent of scoped LGAs
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'state'              AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        WHERE a.adm_level = 1
          AND a.pcode IN (
              SELECT DISTINCT af.parent_pcode
              FROM adm_features af
              JOIN tenant_scope ts ON ts.pcode = af.pcode AND ts.tenant_id = $1
              WHERE af.adm_level = 2
          )

        UNION ALL

        -- LGAs in tenant scope that are NOT grouped into any zone
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'lga'                AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode NOT IN (
              SELECT UNNEST(constituent_pcodes)
              FROM zones
              WHERE tenant_id = $1
          )
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- get_hierarchy(tenant_id)
-- Returns three result sets: states, zones, lgas.
-- Caller assembles the tree.
-- ---------------------------------------------------------------------------
function M.get_hierarchy_states(tenant_id)
    local sql = [[
        SELECT a.pcode, a.name, a.area_sqkm, a.center_lat, a.center_lon
        FROM adm_features a
        WHERE a.adm_level = 1
          AND a.pcode IN (
              SELECT DISTINCT af.parent_pcode
              FROM adm_features af
              JOIN tenant_scope ts ON ts.pcode = af.pcode AND ts.tenant_id = $1
              WHERE af.adm_level = 2
          )
        ORDER BY a.name
    ]]
    return pg.exec(sql, {tenant_id})
end

function M.get_hierarchy_zones(tenant_id)
    local sql = [[
        SELECT zone_pcode, zone_name, color, parent_pcode,
               array_to_string(constituent_pcodes, ',') AS constituent_pcodes
        FROM zones
        WHERE tenant_id = $1
        ORDER BY zone_name
    ]]
    return pg.exec(sql, {tenant_id})
end

function M.get_hierarchy_lgas(tenant_id)
    local sql = [[
        SELECT a.pcode, a.name, a.parent_pcode, a.area_sqkm, a.center_lat, a.center_lon
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode NOT IN (
              SELECT UNNEST(constituent_pcodes)
              FROM zones
              WHERE tenant_id = $1
          )
        ORDER BY a.name
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- search(tenant_id, query)
-- Case-insensitive partial match on name. Returns up to 50 results.
-- ---------------------------------------------------------------------------
function M.search(tenant_id, query)
    local pattern = "%" .. query:lower() .. "%"
    local sql = [[
        SELECT a.pcode, a.name, a.adm_level, a.parent_pcode
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE LOWER(a.name) LIKE $2

        UNION ALL

        SELECT z.zone_pcode AS pcode, z.zone_name AS name, 3 AS adm_level, z.parent_pcode
        FROM zones z
        WHERE z.tenant_id = $1 AND LOWER(z.zone_name) LIKE $2

        ORDER BY adm_level, name
        LIMIT 50
    ]]
    return pg.exec(sql, {tenant_id, pattern})
end

-- ---------------------------------------------------------------------------
-- region_lookup(tenant_id, lat, lon)
-- Returns full hierarchy path for the point: country → state → zone? → lga
-- Checks custom zones first (higher specificity), falls back to raw LGA.
-- ---------------------------------------------------------------------------
function M.region_lookup(tenant_id, lat, lon)
    -- Try zones first — join state name and find the specific LGA inside the zone
    local zone_sql = [[
        SELECT
            z.zone_pcode   AS zone_pcode,
            z.zone_name    AS zone_name,
            z.color        AS zone_color,
            z.parent_pcode AS state_pcode,
            s.name         AS state_name,
            lga.pcode      AS lga_pcode,
            lga.name       AS lga_name
        FROM zones z
        JOIN adm_features s ON s.pcode = z.parent_pcode
        LEFT JOIN adm_features lga
            ON lga.adm_level = 2
           AND lga.pcode = ANY(z.constituent_pcodes)
           AND ST_Contains(lga.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
        WHERE z.tenant_id = $1
          AND ST_Contains(z.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
        LIMIT 1
    ]]
    local zone_result, err = pg.exec(zone_sql, {tenant_id, lat, lon})
    if err then return nil, err end
    if zone_result and #zone_result > 0 then
        local z = zone_result[1]
        return {
            matched_level = "zone",
            state_pcode   = z.state_pcode,
            state_name    = z.state_name,
            zone_pcode    = z.zone_pcode,
            zone_name     = z.zone_name,
            zone_color    = z.zone_color,
            lga_pcode     = z.lga_pcode,
            lga_name      = z.lga_name,
        }, nil
    end

    -- Fallback: raw LGA from tenant scope — join parent state name
    local lga_sql = [[
        SELECT
            a.pcode        AS lga_pcode,
            a.name         AS lga_name,
            a.parent_pcode AS state_pcode,
            s.name         AS state_name
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        JOIN adm_features s  ON s.pcode = a.parent_pcode
        WHERE a.adm_level = 2
          AND ST_Contains(a.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
        LIMIT 1
    ]]
    local lga_result, err2 = pg.exec(lga_sql, {tenant_id, lat, lon})
    if err2 then return nil, err2 end
    if lga_result and #lga_result > 0 then
        local l = lga_result[1]
        return {
            matched_level = "lga",
            state_pcode   = l.state_pcode,
            state_name    = l.state_name,
            lga_pcode     = l.lga_pcode,
            lga_name      = l.lga_name,
        }, nil
    end

    return nil, nil  -- not found (no error)
end

-- ---------------------------------------------------------------------------
-- get_tenant(tenant_id) — returns tenant row for state/country info
-- ---------------------------------------------------------------------------
function M.get_tenant(tenant_id)
    local result, err = pg.exec(
        "SELECT * FROM tenants WHERE tenant_id = $1",
        {tenant_id}
    )
    if err then return nil, err end
    if result and #result > 0 then return result[1], nil end
    return nil, nil
end

return M
