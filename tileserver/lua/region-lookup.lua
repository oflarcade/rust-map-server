-- region-lookup.lua
-- GET /region?lat=<lat>&lon=<lon>
-- Returns the full administrative hierarchy for the given coordinates:
--   country → state → zone (if any) → lga
--
-- Response (found):
--   {
--     found: true, matched_level: "zone"|"lga",
--     -- HDX-style admin hierarchy objects (mirroring adm_features levels)
--     adm_0: { pcode, name },            -- country
--     adm_1: { pcode, name },            -- state / adm1
--     adm_3: { pcode, name, color },     -- zone (only when matched_level === "zone")
--     adm_4: { pcode, name }             -- lga / adm2 (when an LGA match exists)
--   }
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
    -- Fetch country info from tenants table
    local tenant, _ = db.get_tenant(tenant_id)
    local country_pcode = (tenant and tenant.country_code) or ""
    local country_name  = (tenant and tenant.country_name)  or ""

    local payload = {
        found         = true,
        matched_level = row.matched_level,
        -- HDX-style admin hierarchy objects only
        adm_0 = {
            pcode = country_pcode,
            name  = country_name,
        },
        adm_1 = {
            pcode = row.state_pcode,
            name  = row.state_name,
        },
    }

    if row.matched_level == "zone" then
        -- zone_chain is ordered shallowest→deepest; zone_level=1 maps to adm_3, level=2 to adm_4, etc.
        local max_zone_level = 1
        for _, z in ipairs(row.zone_chain or {}) do
            local adm_key = "adm_" .. (tonumber(z.zone_level) + 2)
            payload[adm_key] = {
                pcode  = z.zone_pcode,
                name   = z.zone_name,
                color  = z.zone_color,
            }
            if z.zone_type_label then
                payload[adm_key].type = z.zone_type_label
            end
            local lvl = tonumber(z.zone_level) or 1
            if lvl > max_zone_level then max_zone_level = lvl end
        end
        -- LGA sits one slot above the deepest zone level
        if row.lga_pcode then
            local lga_key = "adm_" .. (max_zone_level + 3)
            payload[lga_key] = { pcode = row.lga_pcode, name = row.lga_name }
        end
    else
        payload.adm_4 = { pcode = row.lga_pcode, name = row.lga_name }
    end

    local body = cjson.encode(payload)
    if region_cache then region_cache:set(cache_key, "200\n" .. body, 3600) end
    ngx.say(body)
else
    local body = cjson.encode({
        found = false,
        error = "Coordinates do not fall within any known boundary for this tenant",
        code  = "REGION_NOT_FOUND",
        lat   = lat,
        lon   = lon,
    })
    if region_cache then region_cache:set(cache_key, "404\n" .. body, 3600) end
    ngx.status = 404
    ngx.say(body)
end
