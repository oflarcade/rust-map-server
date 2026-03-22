-- boundary-db.lua
-- All PostGIS queries for boundary endpoints.
-- Called by serve-geojson, serve-hierarchy, search-boundaries, region-lookup.

local pg = require("pg-pool")

local M = {}

-- Canonical adm level type names merged into GET .../level-labels per country_code,
-- unioned with DISTINCT adm_features.level_label (so operators see INEC types before import).
local CANONICAL_LEVEL_LABELS = {
    NG = {
        "Emirate",
        "Federal Constituency",
        "Local Government Area",
        "Senatorial District",
        "Ward",
    },
    KE = {
        "Sub-County",
        "Ward",
    },
    UG = {
        "County",
        "District",
        "Parish",
        "Sub-County",
    },
    RW = {
        "Cell",
        "District",
        "Sector",
        "Village",
    },
    LR = {
        "Clan",
        "District",
    },
    CF = {
        "Commune",
        "Sous-préfecture",
    },
    IN = {
        "District",
        "Sub-District",
    },
}

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
            z.zone_level,
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
            NULL::SMALLINT       AS zone_level,
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
            NULL::SMALLINT       AS zone_level,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode NOT IN (
              SELECT UNNEST(constituent_pcodes)
              FROM zones
              WHERE tenant_id = $1 AND children_type = 'lga'
          )

        UNION ALL

        -- Grouped LGAs: geometry only, for client-side highlight lookups (not rendered)
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'grouped_lga'        AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL::SMALLINT       AS zone_level,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode IN (
              SELECT UNNEST(constituent_pcodes)
              FROM zones
              WHERE tenant_id = $1 AND children_type = 'lga'
          )

        UNION ALL

        -- adm3+ features: geometry for client-side highlight (not rendered as a layer)
        -- Covers Wards (NG), Sectors (RW), and any other sub-district admin level
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'ward'               AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL::SMALLINT       AS zone_level,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level >= 3
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
        SELECT zone_pcode, zone_name, zone_type_label, zone_level, children_type,
               color, parent_pcode,
               array_to_string(constituent_pcodes, ',') AS constituent_pcodes
        FROM zones
        WHERE tenant_id = $1
        ORDER BY zone_level, zone_name
    ]]
    return pg.exec(sql, {tenant_id})
end

function M.get_hierarchy_lgas(tenant_id)
    local sql = [[
        SELECT a.pcode, a.name, a.parent_pcode, a.level_label, a.area_sqkm, a.center_lat, a.center_lon
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode NOT IN (
              SELECT UNNEST(constituent_pcodes)
              FROM zones
              WHERE tenant_id = $1 AND children_type = 'lga'
          )
        ORDER BY a.name
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- get_hierarchy_adm_features(tenant_id)
-- Returns ALL adm levels in tenant scope (adm1 through adm5+).
-- Used to build the recursive children tree.
-- ---------------------------------------------------------------------------
function M.get_hierarchy_adm_features(tenant_id)
    local sql = [[
        SELECT a.pcode, a.name, a.adm_level, a.level_label, a.parent_pcode,
               a.area_sqkm, a.center_lat, a.center_lon
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        ORDER BY a.adm_level, a.name
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
    -- Find all zones containing the point, deepest first.
    -- We fetch all matches so we can walk the parent chain in Lua.
    local zone_sql = [[
        SELECT z.zone_pcode, z.zone_name, z.zone_type_label, z.zone_level,
               z.parent_pcode, z.color AS zone_color
        FROM zones z
        WHERE z.tenant_id = $1
          AND ST_Contains(z.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
        ORDER BY z.zone_level DESC
    ]]
    local zone_rows, err = pg.exec(zone_sql, {tenant_id, lat, lon})
    if err then return nil, err end

    -- Always look up the LGA (adm_level=2) containing the point
    local lga_sql = [[
        SELECT a.pcode AS lga_pcode, a.name AS lga_name,
               a.parent_pcode AS state_pcode, s.name AS state_name
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        JOIN adm_features s  ON s.pcode = a.parent_pcode
        WHERE a.adm_level = 2
          AND ST_Contains(a.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
        LIMIT 1
    ]]
    local lga_result, err2 = pg.exec(lga_sql, {tenant_id, lat, lon})
    if err2 then return nil, err2 end

    local lga_row = lga_result and lga_result[1]

    if zone_rows and #zone_rows > 0 then
        -- Build a lookup from zone_pcode -> zone row
        local zone_by_pcode = {}
        for _, z in ipairs(zone_rows) do
            zone_by_pcode[z.zone_pcode] = z
        end

        -- Start from the deepest zone (first row, highest zone_level)
        local deepest = zone_rows[1]

        -- Walk up the parent chain collecting zones (deepest → shallowest order from traversal)
        local chain = {}
        local current = deepest
        local MAX_DEPTH = 10
        for _ = 1, MAX_DEPTH do
            table.insert(chain, 1, current)  -- prepend to get shallowest first
            local parent = zone_by_pcode[current.parent_pcode]
            if not parent then break end
            current = parent
        end

        -- state_pcode is the parent of the topmost zone in the chain
        local state_pcode = chain[1].parent_pcode
        local state_name  = ""
        if lga_row and lga_row.state_pcode == state_pcode then
            state_name = lga_row.state_name
        else
            -- fetch state name directly
            local s_res, _ = pg.exec(
                "SELECT name FROM adm_features WHERE pcode = $1 AND adm_level = 1",
                {state_pcode}
            )
            if s_res and #s_res > 0 then state_name = s_res[1].name end
        end

        return {
            matched_level = "zone",
            state_pcode   = state_pcode,
            state_name    = state_name,
            zone_chain    = chain,  -- ordered shallowest → deepest
            lga_pcode     = lga_row and lga_row.lga_pcode,
            lga_name      = lga_row and lga_row.lga_name,
        }, nil
    end

    -- Fallback: raw LGA only
    if lga_row then
        return {
            matched_level = "lga",
            state_pcode   = lga_row.state_pcode,
            state_name    = lga_row.state_name,
            lga_pcode     = lga_row.lga_pcode,
            lga_name      = lga_row.lga_name,
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

-- ---------------------------------------------------------------------------
-- get_geo_levels(tenant_id) — list hierarchy levels for tenant
-- ---------------------------------------------------------------------------
function M.get_geo_levels(tenant_id)
    local sql = [[
        SELECT id, level_order, level_label, level_code
        FROM geo_hierarchy_levels
        WHERE tenant_id = $1
        ORDER BY level_order
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- get_geo_nodes(tenant_id) — full node list with level info for tree building
-- ---------------------------------------------------------------------------
function M.get_geo_nodes(tenant_id)
    local sql = [[
        SELECT n.id, n.parent_id, n.state_pcode, n.pcode, n.name, n.color,
               array_to_string(n.constituent_pcodes, ',') AS constituent_pcodes,
               n.area_sqkm, n.center_lat, n.center_lon,
               l.level_order, l.level_label
        FROM geo_hierarchy_nodes n
        JOIN geo_hierarchy_levels l ON l.id = n.level_id
        WHERE n.tenant_id = $1
        ORDER BY l.level_order, n.name
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- get_geo_nodes_geojson(tenant_id) — for /boundaries/geojson endpoint
-- Returns geo nodes + states + ungrouped LGAs + grouped LGAs + wards
-- ---------------------------------------------------------------------------
function M.get_geo_nodes_geojson(tenant_id)
    local sql = [[
        -- Geo hierarchy nodes (pre-computed union geometry)
        SELECT
            ST_AsGeoJSON(n.geom)                             AS geometry,
            n.pcode,
            n.name,
            'geo_node'                                       AS feature_type,
            n.state_pcode                                    AS parent_pcode,
            n.color,
            l.level_order::SMALLINT                          AS zone_level,
            array_to_string(n.constituent_pcodes, ',')       AS constituent_pcodes
        FROM geo_hierarchy_nodes n
        JOIN geo_hierarchy_levels l ON l.id = n.level_id
        WHERE n.tenant_id = $1
          AND n.geom IS NOT NULL

        UNION ALL

        -- States: derived from the parent of scoped LGAs
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'state'              AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL::SMALLINT       AS zone_level,
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

        -- LGAs in tenant scope NOT assigned to any geo hierarchy node
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'lga'                AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL::SMALLINT       AS zone_level,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode NOT IN (
              SELECT UNNEST(constituent_pcodes)
              FROM geo_hierarchy_nodes
              WHERE tenant_id = $1 AND constituent_pcodes IS NOT NULL
          )

        UNION ALL

        -- Grouped LGAs: geometry for client-side highlight (not rendered as layer)
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'grouped_lga'        AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL::SMALLINT       AS zone_level,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level = 2
          AND a.pcode IN (
              SELECT UNNEST(constituent_pcodes)
              FROM geo_hierarchy_nodes
              WHERE tenant_id = $1 AND constituent_pcodes IS NOT NULL
          )

        UNION ALL

        -- adm3+ features (wards, sectors, etc.)
        SELECT
            ST_AsGeoJSON(a.geom) AS geometry,
            a.pcode,
            a.name,
            'ward'               AS feature_type,
            a.parent_pcode,
            NULL                 AS color,
            NULL::SMALLINT       AS zone_level,
            NULL                 AS constituent_pcodes
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        WHERE a.adm_level >= 3
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- get_hdx_level_labels(tenant_id)
-- Distinct adm_features.level_label for the tenant's country (from `tenants.country_code`).
-- Includes adm_level >= 2 so INEC/HDX types at adm3–5 (Senatorial District, Federal
-- Constituency, Emirate, Ward, …) all appear, not only adm3. Still per-tenant via
-- country row (Kenya tenant → KE labels, Nigeria → NG).
-- ---------------------------------------------------------------------------
function M.get_hdx_level_labels(tenant_id)
    local sql = [[
        SELECT DISTINCT af.level_label
        FROM adm_features af
        INNER JOIN tenants t ON t.country_code = af.country_code AND t.tenant_id = $1
        WHERE af.adm_level >= 2
          AND af.level_label IS NOT NULL
          AND BTRIM(af.level_label) <> ''
        ORDER BY af.level_label
    ]]
    return pg.exec(sql, {tenant_id})
end

-- ---------------------------------------------------------------------------
-- get_level_labels_for_tenant(tenant_id)
-- Union of DISTINCT DB labels for the tenant's country with CANONICAL_LEVEL_LABELS.
-- Returns an alphabetically sorted array of strings, or nil, err on DB failure.
-- ---------------------------------------------------------------------------
function M.get_level_labels_for_tenant(tenant_id)
    local rows, err = M.get_hdx_level_labels(tenant_id)
    if err then return nil, err end

    local seen = {}
    for _, r in ipairs(rows or {}) do
        local lbl = r.level_label
        if lbl and lbl ~= ngx.null then
            local t = (lbl:gsub("^%s+", ""):gsub("%s+$", ""))
            if t ~= "" then
                seen[t] = true
            end
        end
    end

    local trows, err2 = pg.exec([[
        SELECT UPPER(TRIM(BOTH FROM country_code::text)) AS cc
        FROM tenants
        WHERE tenant_id = $1
        LIMIT 1
    ]], {tenant_id})
    if err2 then return nil, err2 end

    local cc = trows and trows[1] and trows[1].cc
    if cc and cc ~= ngx.null and cc ~= "" then
        local extras = CANONICAL_LEVEL_LABELS[cc]
        if extras then
            for _, lbl in ipairs(extras) do
                seen[lbl] = true
            end
        end
    end

    local out = {}
    for lbl, _ in pairs(seen) do
        table.insert(out, lbl)
    end
    table.sort(out)
    return out, nil
end

-- ---------------------------------------------------------------------------
-- region_geo_lookup(tenant_id, lat, lon)
-- Finds the deepest geo_hierarchy_node containing the point.
-- Returns nil if no geo nodes exist for tenant (caller falls back to LGA lookup).
-- ---------------------------------------------------------------------------
function M.region_geo_lookup(tenant_id, lat, lon)
    local sql = [[
        SELECT n.id, n.pcode, n.name, n.color, n.parent_id, n.state_pcode,
               l.level_order, l.level_label
        FROM geo_hierarchy_nodes n
        JOIN geo_hierarchy_levels l ON l.id = n.level_id
        WHERE n.tenant_id = $1
          AND n.geom IS NOT NULL
          AND ST_Contains(n.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
        ORDER BY l.level_order DESC
        LIMIT 1
    ]]
    local rows, err = pg.exec(sql, {tenant_id, lat, lon})
    if err then return nil, err end
    if not rows or #rows == 0 then return nil, nil end
    return rows[1], nil
end

-- ---------------------------------------------------------------------------
-- get_geo_node_chain(node_id)
-- Returns the ancestor chain from root to the given node (level_order ASC).
-- Used by region-lookup to build full adm_N key chain.
-- ---------------------------------------------------------------------------
function M.get_geo_node_chain(node_id)
    local sql = [[
        WITH RECURSIVE chain AS (
            SELECT n.id, n.parent_id, n.pcode, n.name, n.color, n.state_pcode,
                   l.level_order, l.level_label
            FROM geo_hierarchy_nodes n
            JOIN geo_hierarchy_levels l ON l.id = n.level_id
            WHERE n.id = $1
            UNION ALL
            SELECT n.id, n.parent_id, n.pcode, n.name, n.color, n.state_pcode,
                   l.level_order, l.level_label
            FROM geo_hierarchy_nodes n
            JOIN geo_hierarchy_levels l ON l.id = n.level_id
            JOIN chain c ON n.id = c.parent_id
        )
        SELECT id, parent_id, pcode, name, color, state_pcode, level_order, level_label
        FROM chain
        ORDER BY level_order ASC
    ]]
    return pg.exec(sql, {node_id})
end

-- ---------------------------------------------------------------------------
-- tenant_cache helpers  (persistent L2 cache in Postgres)
-- ---------------------------------------------------------------------------

-- Returns the cached payload string, or nil if not found / on error.
function M.get_tenant_cache(tenant_id, key)
    local rows, err = pg.exec(
        "SELECT payload FROM tenant_cache WHERE tenant_id = $1 AND cache_key = $2",
        {tenant_id, key}
    )
    if err or not rows or #rows == 0 then return nil end
    return rows[1].payload
end

-- Upserts a payload into tenant_cache. Non-fatal: errors are logged, not raised.
function M.set_tenant_cache(tenant_id, key, payload)
    local _, err = pg.exec([[
        INSERT INTO tenant_cache (tenant_id, cache_key, payload, updated_at)
        VALUES ($1, $2, $3, now())
        ON CONFLICT (tenant_id, cache_key)
        DO UPDATE SET payload = EXCLUDED.payload, updated_at = now()
    ]], {tenant_id, key, payload})
    if err then
        ngx.log(ngx.WARN, "tenant_cache:set failed t=" .. tenant_id .. " k=" .. key .. ": " .. err)
    end
end

-- Deletes all cache entries for a tenant (call on any admin write).
function M.delete_tenant_cache(tenant_id)
    pg.exec("DELETE FROM tenant_cache WHERE tenant_id = $1", {tenant_id})
end

return M
