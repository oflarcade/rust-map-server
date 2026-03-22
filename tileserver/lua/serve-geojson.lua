-- serve-geojson.lua
-- GET /boundaries/geojson
-- Streams a GeoJSON FeatureCollection for the tenant from PostGIS.
-- Uses geo_hierarchy_nodes (new model); ungrouped LGAs + states + wards included.
-- Server-side cache: ngx.shared.geojson_cache (32MB, keyed "gj:{tenant_id}", 86400s TTL).

local cjson = require("cjson.safe")
local db    = require("boundary-db")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)

local geojson_cache = ngx.shared.geojson_cache
local cache_key     = "gj:" .. tenant_id

local function send_geojson(body, x_cache)
    ngx.header["Content-Type"]  = "application/geo+json"
    ngx.header["Cache-Control"] = "public, max-age=86400"
    ngx.header["Vary"]          = "X-Tenant-ID"
    ngx.header["X-Cache"]       = x_cache
    ngx.print(body)
end

-- L1: ngx.shared
local cached = geojson_cache and geojson_cache:get(cache_key)
if cached then send_geojson(cached, "HIT"); return end

-- L2: tenant_cache in Postgres (survives restarts)
local l2 = db.get_tenant_cache(tenant_id, "geojson")
if l2 then
    if geojson_cache then geojson_cache:set(cache_key, l2, 86400) end
    send_geojson(l2, "L2-HIT")
    return
end

-- ---------------------------------------------------------------------------
-- Cache miss — query PostGIS
-- ---------------------------------------------------------------------------
local rows, err = db.get_geo_nodes_geojson(tenant_id)
if err then
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err }))
    return
end

-- Build body string (buffer in memory for caching; payloads are 1-4 MB)
local parts = { '{"type":"FeatureCollection","features":[' }
local first = true
for _, row in ipairs(rows or {}) do
    if row.geometry then
        local props = {
            pcode        = row.pcode,
            name         = row.name,
            feature_type = row.feature_type,
            parent_pcode = row.parent_pcode,
        }
        if row.color and row.color ~= "" then
            props.color = row.color
        end
        if row.zone_level then
            props.zone_level = tonumber(row.zone_level)
        end
        if row.constituent_pcodes and row.constituent_pcodes ~= "" then
            props.constituent_pcodes = row.constituent_pcodes
        end

        local feature = '{"type":"Feature","geometry":' .. row.geometry ..
                        ',"properties":' .. cjson.encode(props) .. '}'
        if not first then parts[#parts + 1] = ',' end
        parts[#parts + 1] = feature
        first = false
    end
end
parts[#parts + 1] = ']}'

local body = table.concat(parts)

-- ---------------------------------------------------------------------------
-- Cache write (non-fatal on failure — e.g. slab full)
-- ---------------------------------------------------------------------------
if geojson_cache then
    local ok, store_err = geojson_cache:set(cache_key, body, 86400)
    if not ok then
        ngx.log(ngx.WARN, "geojson_cache:set failed for tenant " .. tenant_id .. ": " .. tostring(store_err))
    end
end
db.set_tenant_cache(tenant_id, "geojson", body)
send_geojson(body, "MISS")
