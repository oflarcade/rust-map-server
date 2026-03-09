-- serve-hierarchy.lua
-- GET /boundaries/hierarchy
-- Returns a JSON hierarchy tree for the tenant from PostGIS.
-- Format matches the pre-built HDX hierarchy JSON files exactly,
-- with an additional optional "zones" array per state.
-- Result is cached in ngx.shared.hierarchy_cache (8MB, keyed by tenant_id).

local cjson = require("cjson.safe")
local db    = require("boundary-db")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)
local cache_key = "h:" .. tenant_id

-- L1 cache check
local hierarchy_cache = ngx.shared.hierarchy_cache
if hierarchy_cache then
    local cached = hierarchy_cache:get(cache_key)
    if cached then
        ngx.header["Content-Type"]  = "application/json"
        ngx.header["Cache-Control"] = "public, max-age=86400"
        ngx.header["X-Cache"]       = "HIT"
        ngx.print(cached)
        return
    end
end

-- Fetch from DB
local states_rows, err1 = db.get_hierarchy_states(tenant_id)
local zones_rows,  err2 = db.get_hierarchy_zones(tenant_id)
local lgas_rows,   err3 = db.get_hierarchy_lgas(tenant_id)

if err1 or err2 or err3 then
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        error  = "Database error",
        code   = "DB_ERROR",
        detail = err1 or err2 or err3,
    }))
    return
end

-- Build lookup tables
local zones_by_state = {}  -- parent_pcode -> [zone, ...]
for _, z in ipairs(zones_rows or {}) do
    local list = zones_by_state[z.parent_pcode] or {}
    local pcodes = {}
    for p in (z.constituent_pcodes or ""):gmatch("[^,]+") do
        table.insert(pcodes, p)
    end
    table.insert(list, {
        zone_pcode          = z.zone_pcode,
        zone_name           = z.zone_name,
        color               = z.color,
        parent_pcode        = z.parent_pcode,
        constituent_pcodes  = pcodes,
    })
    zones_by_state[z.parent_pcode] = list
end

local lgas_by_state = {}  -- parent_pcode -> [lga, ...]
for _, l in ipairs(lgas_rows or {}) do
    local list = lgas_by_state[l.parent_pcode] or {}
    table.insert(list, {
        pcode      = l.pcode,
        name       = l.name,
        area_sqkm  = tonumber(l.area_sqkm),
        center_lat = tonumber(l.center_lat),
        center_lon = tonumber(l.center_lon),
    })
    lgas_by_state[l.parent_pcode] = list
end

-- Get tenant metadata for top-level fields
local tenant, _ = db.get_tenant(tenant_id)
local country_pcode = (tenant and tenant.country_code) or ""
local hdx_prefix    = (tenant and tenant.hdx_prefix)   or ""

-- Assemble states list
local states = {}
local lga_count  = 0
local zone_count = 0

for _, s in ipairs(states_rows or {}) do
    local lgas  = lgas_by_state[s.pcode]  or {}
    local zones = zones_by_state[s.pcode] or {}
    lga_count  = lga_count  + #lgas
    zone_count = zone_count + #zones

    local state_entry = {
        pcode      = s.pcode,
        name       = s.name,
        area_sqkm  = tonumber(s.area_sqkm),
        center_lat = tonumber(s.center_lat),
        center_lon = tonumber(s.center_lon),
        lgas       = lgas,
    }
    if #zones > 0 then
        state_entry.zones = zones
    end
    table.insert(states, state_entry)
end

-- Build final response (matches existing HDX hierarchy JSON format)
local response = {
    pcode        = country_pcode,
    name         = (tenant and tenant.country_name) or "",
    source       = "PostGIS",
    state_count  = #states,
    lga_count    = lga_count,
    states       = states,
}
if zone_count > 0 then
    response.zone_count = zone_count
end

local body = cjson.encode(response)

-- Store in cache (invalidated on zone write)
if hierarchy_cache then
    hierarchy_cache:set(cache_key, body, 86400)
end

ngx.header["Content-Type"]  = "application/json"
ngx.header["Cache-Control"] = "public, max-age=86400"
ngx.header["X-Cache"]       = "MISS"
ngx.print(body)
