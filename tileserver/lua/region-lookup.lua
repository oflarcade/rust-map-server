-- region-lookup.lua
-- GET /region?lat=<lat>&lon=<lon>
-- Returns the zone or LGA containing the given coordinates via PostGIS ST_Contains.
-- Keeps the ngx.shared result cache (L1) for sub-ms repeat hits.
--
-- Response (found):
--   { found, pcode, level, name, state_pcode, adm2_pcode, adm2_name }
-- Response (not found):
--   { found: false, error, code, lat, lon }

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

local row, err = db.region_lookup(tenant_id, lat, lon)

if err then
    ngx.status = 502
    local body = cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err })
    ngx.say(body)
    return
end

if row then
    local payload = cjson.encode({
        found       = true,
        pcode       = row.pcode,
        level       = row.level,
        name        = row.name,
        state_pcode = row.state_pcode,
        adm2_pcode  = row.adm2_pcode,
        adm2_name   = row.adm2_name,
    })
    if region_cache then region_cache:set(cache_key, "200\n" .. payload, 3600) end
    ngx.say(payload)
else
    local payload = cjson.encode({
        found = false,
        error = "Coordinates do not fall within any known boundary for this tenant",
        code  = "REGION_NOT_FOUND",
        lat   = lat,
        lon   = lon,
    })
    if region_cache then region_cache:set(cache_key, "404\n" .. payload, 3600) end
    ngx.status = 404
    ngx.say(payload)
end
