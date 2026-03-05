-- search-boundaries.lua
-- GET /boundaries/search?q=<query>[&type=hdx]
-- Case-insensitive partial match against boundary names for the current tenant.
--
-- ?type=hdx  -> searches adm1_name / adm2_name in HDX files
-- (default)  -> searches name / admin_level in OSM GeoJSON
--
-- Response: { query, type, count, results: [{level, name fields, pcode/osm_id}] }

local cjson = require("cjson.safe")

local q     = ngx.var.arg_q    or ""
local btype = ngx.var.arg_type or ""

if q == "" then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Missing required parameter: ?q=","code":"MISSING_QUERY"}')
    return
end

local q_lower = q:lower()

local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local results = {}

if btype == "hdx" then
    local prefix = ngx.var.hdx_prefix
    if not prefix or prefix == "" then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"No HDX boundary data for this tenant","code":"HDX_NOT_AVAILABLE"}')
        return
    end

    local function search_hdx(path, level)
        local content = read_all(path)
        if not content then return end
        local data = cjson.decode(content)
        if not data or not data.features then return end
        for _, feat in ipairs(data.features) do
            local p    = feat.properties or {}
            local name = level == "adm1" and (p.adm1_name or "") or (p.adm2_name or "")
            if name:lower():find(q_lower, 1, true) then
                local hit = { level = level, adm1_name = p.adm1_name, adm1_pcode = p.adm1_pcode }
                if level == "adm2" then
                    hit.adm2_name  = p.adm2_name
                    hit.adm2_pcode = p.adm2_pcode
                end
                table.insert(results, hit)
            end
        end
    end

    search_hdx("/data/hdx/" .. prefix .. "_adm1.geojson", "adm1")
    search_hdx("/data/hdx/" .. prefix .. "_adm2.geojson", "adm2")

else
    -- OSM: search the 'name' property in the tenant boundary GeoJSON
    local source = ngx.var.boundary_source
    if not source or source == "" then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"No boundary data for this tenant","code":"NO_BOUNDARY_DATA"}')
        return
    end

    local content = read_all("/data/boundaries/" .. source .. ".geojson")
    if not content then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"GeoJSON not found","code":"GEOJSON_NOT_FOUND","source":"' .. source .. '"}')
        return
    end

    local data = cjson.decode(content)
    if data and data.features then
        for _, feat in ipairs(data.features) do
            local p    = feat.properties or {}
            local name = p.name or ""
            if name:lower():find(q_lower, 1, true) then
                table.insert(results, {
                    level       = p.admin_level == "4" and "state" or "lga",
                    name        = p.name,
                    admin_level = p.admin_level,
                    osm_id      = p.osm_id,
                })
            end
        end
    end
end

ngx.header["Content-Type"]  = "application/json"
ngx.header["Cache-Control"] = "no-store"
ngx.say(cjson.encode({
    query   = q,
    type    = (btype == "" and "osm" or btype),
    count   = #results,
    results = results,
}))
