-- region-lookup.lua
-- GET /region?lat=<lat>&lon=<lon>
-- Returns the HDX pcode of the admin region containing the given coordinates.
-- Searches adm2 (LGA/district) first; falls back to adm1 (state/region) if no adm2 match.
--
-- Response:
--   { found: true,  pcode, level, adm2_pcode, adm2_name, adm1_pcode, adm1_name, adm0_pcode, adm0_name }
--   { found: false, error, code, lat, lon }

local cjson = require("cjson.safe")
local hdx_cache = require("hdx-cache")

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

local prefix = ngx.var.hdx_prefix
if not prefix or prefix == "" then
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"No HDX data for this tenant","code":"HDX_NOT_AVAILABLE"}')
    return
end

local cache_key = prefix .. ":" .. string.format("%.4f", lat) .. ":" .. string.format("%.4f", lon)
local region_cache = ngx.shared.region_cache
if region_cache then
    local cached = region_cache:get(cache_key)
    if cached then
        local status_code, body = cached:match("^(%d+)\n(.+)$")
        if status_code then
            ngx.status = tonumber(status_code)
            ngx.header["Content-Type"] = "application/json"
            ngx.header["Cache-Control"] = "no-store"
            ngx.say(body)
            return
        end
    end
end

-- Ray-casting point-in-polygon for a single coordinate ring
local function point_in_ring(px, py, ring)
    local inside = false
    local n = #ring
    local j = n
    for i = 1, n do
        local xi, yi = ring[i][1], ring[i][2]
        local xj, yj = ring[j][1], ring[j][2]
        if (yi > py) ~= (yj > py) and
           px < (xj - xi) * (py - yi) / (yj - yi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Test a point (px=longitude, py=latitude) against a GeoJSON geometry
local function point_in_geometry(px, py, geometry)
    local gtype = geometry.type
    if gtype == "Polygon" then
        return point_in_ring(px, py, geometry.coordinates[1])
    elseif gtype == "MultiPolygon" then
        for _, poly in ipairs(geometry.coordinates) do
            if point_in_ring(px, py, poly[1]) then return true end
        end
    end
    return false
end

-- Search adm2 (LGA / district level) first
local adm2 = hdx_cache.get_adm(prefix, "adm2")
if not adm2 then
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"HDX data not found. Run download-hdx.ps1","code":"HDX_NOT_AVAILABLE"}')
    return
end

ngx.header["Content-Type"]  = "application/json"
ngx.header["Cache-Control"] = "no-store"

for _, feat in ipairs(adm2.features) do
    if feat.geometry and point_in_geometry(lon, lat, feat.geometry) then
        local p = feat.properties
        local payload = cjson.encode({
            found      = true,
            pcode      = p.adm2_pcode,
            level      = "adm2",
            adm2_pcode = p.adm2_pcode,
            adm2_name  = p.adm2_name,
            adm1_pcode = p.adm1_pcode,
            adm1_name  = p.adm1_name,
            adm0_pcode = p.adm0_pcode,
            adm0_name  = p.adm0_name,
        })
        if region_cache then region_cache:set(cache_key, "200\n" .. payload, 3600) end
        ngx.header["Content-Type"]  = "application/json"
        ngx.header["Cache-Control"] = "no-store"
        ngx.say(payload)
        return
    end
end

-- Fallback: search adm1 (state / region level)
local adm1 = hdx_cache.get_adm(prefix, "adm1")
if adm1 then
    for _, feat in ipairs(adm1.features) do
        if feat.geometry and point_in_geometry(lon, lat, feat.geometry) then
            local p = feat.properties
            local payload = cjson.encode({
                found      = true,
                pcode      = p.adm1_pcode,
                level      = "adm1",
                adm1_pcode = p.adm1_pcode,
                adm1_name  = p.adm1_name,
                adm0_pcode = p.adm0_pcode,
                adm0_name  = p.adm0_name,
            })
            if region_cache then region_cache:set(cache_key, "200\n" .. payload, 3600) end
            ngx.header["Content-Type"]  = "application/json"
            ngx.header["Cache-Control"] = "no-store"
            ngx.say(payload)
            return
        end
    end
end

-- No match at any level
local payload = cjson.encode({
    found = false,
    error = "Coordinates do not fall within any known boundary for this tenant",
    code  = "REGION_NOT_FOUND",
    lat   = lat,
    lon   = lon,
})
if region_cache then region_cache:set(cache_key, "404\n" .. payload, 3600) end
ngx.status = 404
ngx.header["Content-Type"] = "application/json"
ngx.say(payload)
