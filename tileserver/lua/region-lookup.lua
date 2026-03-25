-- region-lookup.lua
-- GET /region?lat=<lat>&lon=<lon>
-- Returns the full administrative hierarchy for the given coordinates.
-- Uses geo_hierarchy_nodes GIST lookup (new model); falls back to raw adm2.
--
-- Response (found):
--   {
--     found: true, matched_level: "geo_node"|"adm2",
--     adm_0: { pcode, name },             -- country
--     adm_1: { pcode, name },             -- state (adm1)
--     adm_{2+level_order}: { pcode, name, color, level_label },  -- geo node per level
--     adm_{2+max_level_order+1}: { pcode, name }  -- adm2 (when matched, geo_node path)
--     adm_2: { pcode, name }              -- adm2 (fallback: no geo_hierarchy_nodes)
--   }

local cjson = require("cjson.safe")
local db    = require("boundary-db")

-- Validate inputs
local lat_str = ngx.var.arg_lat or ""
local lon_str = ngx.var.arg_lon or ""

if lat_str == "" or lon_str == "" then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Missing required parameters: ?lat= and ?lon=","code":"MISSING_PARAMS"}')
    return
end

local lat = tonumber(lat_str)
local lon = tonumber(lon_str)

if not lat or not lon then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"lat and lon must be numeric","code":"INVALID_PARAMS"}')
    return
end

if lat < -90 or lat > 90 or lon < -180 or lon > 180 then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"lat/lon out of valid range","code":"INVALID_PARAMS"}')
    return
end

local tenant_id = tonumber(ngx.var.http_x_tenant_id)

-- L1 result cache (keyed by tenant + truncated coords)
local cache_key    = tenant_id .. ":" .. string.format("%.4f", lat) .. ":" .. string.format("%.4f", lon)
local region_cache = ngx.shared.region_cache

if region_cache then
    local cached = region_cache:get(cache_key)
    if cached then
        local status_code, body = cached:match("^(%d+)\n(.+)$")
        if status_code then
            ngx.status = tonumber(status_code)
            ngx.header["Content-Type"]  = "application/json"
            ngx.header["Cache-Control"] = "no-store"
            ngx.header["X-Cache"]       = "HIT"
            ngx.say(body)
            return
        end
    end
end

ngx.header["Content-Type"]  = "application/json"
ngx.header["Cache-Control"] = "no-store"
ngx.header["X-Cache"]       = "MISS"

-- Fetch country info from tenants table
local tenant, _ = db.get_tenant(tenant_id)
local country_pcode = (tenant and tenant.country_code) or ""
local country_name  = (tenant and tenant.country_name)  or ""

-- Always look up the adm2 feature containing the point
local adm2_sql = [[
    SELECT a.pcode AS adm2_pcode, a.name AS adm2_name,
           a.parent_pcode AS adm1_pcode, s.name AS adm1_name
    FROM adm_features a
    JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
    JOIN adm_features s  ON s.pcode = a.parent_pcode
    WHERE a.adm_level = 2
      AND ST_Contains(a.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
    LIMIT 1
]]

local pg = require("pg-pool")
local adm2_rows, _ = pg.exec(adm2_sql, {tenant_id, lat, lon})
local adm2_row = adm2_rows and adm2_rows[1]

-- Try geo_hierarchy_nodes lookup first
local deep_node, geo_err = db.region_geo_lookup(tenant_id, lat, lon)

if geo_err then
    ngx.status = 502
    local body = cjson.encode({error="Database error", code="DB_ERROR", detail=geo_err})
    ngx.say(body)
    return
end

local function cache_and_send(status, body)
    if region_cache then region_cache:set(cache_key, status .. "\n" .. body, 3600) end
    ngx.status = tonumber(status)
    ngx.say(body)
end

if deep_node then
    -- Walk ancestor chain to build full adm_N keys
    local chain, chain_err = db.get_geo_node_chain(tonumber(deep_node.id))
    if chain_err then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=chain_err}))
        return
    end

    local payload = {
        found         = true,
        matched_level = "geo_node",
        adm_0 = { pcode = country_pcode, name = country_name },
        adm_1 = {
            pcode = (adm2_row and adm2_row.adm1_pcode) or (deep_node.state_pcode),
            name  = (adm2_row and adm2_row.adm1_name)  or "",
        },
    }

    local max_level_order = 0
    for _, node in ipairs(chain or {}) do
        local lo = tonumber(node.level_order) or 1
        local adm_key = "adm_" .. (lo + 2)
        payload[adm_key] = {
            pcode       = node.pcode,
            name        = node.name,
            color       = node.color,
            level_label = node.level_label,
        }
        if lo > max_level_order then max_level_order = lo end
    end

    -- adm2 sits one level above the deepest geo node
    if adm2_row then
        local adm2_key = "adm_" .. (max_level_order + 3)
        payload[adm2_key] = { pcode = adm2_row.adm2_pcode, name = adm2_row.adm2_name }
    end

    local body = cjson.encode(payload)
    cache_and_send("200", body)
    return
end

-- Fallback: adm2 only (no geo_hierarchy_nodes for this tenant)
-- adm2 sits directly under adm1, so it goes at adm_2.
if adm2_row then
    local payload = {
        found         = true,
        matched_level = "adm2",
        adm_0 = { pcode = country_pcode, name = country_name },
        adm_1 = { pcode = adm2_row.adm1_pcode, name = adm2_row.adm1_name },
        adm_2 = { pcode = adm2_row.adm2_pcode, name = adm2_row.adm2_name },
    }
    local body = cjson.encode(payload)
    cache_and_send("200", body)
    return
end

-- Not found
local body = cjson.encode({
    found = false,
    error = "Coordinates do not fall within any known boundary for this tenant",
    code  = "REGION_NOT_FOUND",
    lat   = lat,
    lon   = lon,
})
cache_and_send("404", body)
