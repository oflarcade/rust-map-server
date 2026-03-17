-- serve-hierarchy.lua
-- GET /boundaries/hierarchy
-- Returns a JSON hierarchy tree for the tenant from PostGIS.
-- Backward-compatible: each state still has `lgas` and `zones` arrays.
-- New: each state also has a `children` array for adm3+ levels (variable depth).
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
        ngx.header["Vary"]          = "X-Tenant-ID"
        ngx.header["X-Cache"]       = "HIT"
        ngx.print(cached)
        return
    end
end

-- Fetch from DB — three queries run independently
local adm_rows,   err1 = db.get_hierarchy_adm_features(tenant_id)
local zones_rows, err2 = db.get_hierarchy_zones(tenant_id)
local lgas_rows,  err3 = db.get_hierarchy_lgas(tenant_id)

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

-- ---------------------------------------------------------------------------
-- Index adm_features by pcode and by (adm_level, parent_pcode)
-- ---------------------------------------------------------------------------
local adm_by_pcode    = {}   -- pcode -> row
local adm3plus_by_parent = {} -- parent_pcode -> [adm3+ rows]  (adm_level >= 3)
local states_list = {}        -- adm_level=1 rows, ordered

for _, a in ipairs(adm_rows or {}) do
    adm_by_pcode[a.pcode] = a
    if tonumber(a.adm_level) == 1 then
        table.insert(states_list, a)
    elseif tonumber(a.adm_level) >= 3 then
        if a.parent_pcode then
            local list = adm3plus_by_parent[a.parent_pcode] or {}
            table.insert(list, a)
            adm3plus_by_parent[a.parent_pcode] = list
        end
    end
end

-- ---------------------------------------------------------------------------
-- Index zones
-- ---------------------------------------------------------------------------
local zones_by_state  = {}  -- state_pcode  -> [zones with zone_level=1]  (backward compat)
local zones_by_parent = {}  -- parent_pcode -> [all zones]                 (for children tree)

for _, z in ipairs(zones_rows or {}) do
    local pcodes = {}
    for p in (z.constituent_pcodes or ""):gmatch("[^,]+") do
        table.insert(pcodes, p)
    end
    local zone_entry = {
        zone_pcode          = z.zone_pcode,
        zone_name           = z.zone_name,
        zone_type_label     = z.zone_type_label,
        zone_level          = tonumber(z.zone_level) or 1,
        children_type       = z.children_type,
        color               = z.color,
        parent_pcode        = z.parent_pcode,
        constituent_pcodes  = pcodes,
    }

    -- backward-compat: state.zones contains only level-1 zones parented to a state
    local is_state_pcode = adm_by_pcode[z.parent_pcode] and
                           tonumber(adm_by_pcode[z.parent_pcode].adm_level) == 1
    if tonumber(z.zone_level) == 1 and is_state_pcode then
        local list = zones_by_state[z.parent_pcode] or {}
        table.insert(list, zone_entry)
        zones_by_state[z.parent_pcode] = list
    end

    -- all zones indexed by parent for the children tree
    local zlist = zones_by_parent[z.parent_pcode] or {}
    table.insert(zlist, zone_entry)
    zones_by_parent[z.parent_pcode] = zlist
end

-- ---------------------------------------------------------------------------
-- Backward-compat: LGAs by state
-- ---------------------------------------------------------------------------
local lgas_by_state = {}  -- parent_pcode -> [lga, ...]
for _, l in ipairs(lgas_rows or {}) do
    if l.parent_pcode then
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
end

-- ---------------------------------------------------------------------------
-- Recursive children builder
-- Builds a depth-first children list for a given parent pcode.
-- Attaches adm3+ features AND zones as children nodes.
-- ---------------------------------------------------------------------------
local function build_children(parent_pcode, depth)
    if depth > 8 then return nil end  -- guard against runaway recursion

    local children = {}

    -- adm3+ features parented here
    for _, a in ipairs(adm3plus_by_parent[parent_pcode] or {}) do
        local node = {
            pcode       = a.pcode,
            name        = a.name,
            level       = tonumber(a.adm_level),
            level_label = a.level_label,
            area_sqkm   = tonumber(a.area_sqkm),
            center_lat  = tonumber(a.center_lat),
            center_lon  = tonumber(a.center_lon),
        }
        local sub = build_children(a.pcode, depth + 1)
        if sub and #sub > 0 then node.children = sub end
        table.insert(children, node)
    end

    -- zones parented here (any zone_level)
    for _, z in ipairs(zones_by_parent[parent_pcode] or {}) do
        local node = {
            zone_pcode         = z.zone_pcode,
            name               = z.zone_name,
            zone_name          = z.zone_name,
            zone_type_label    = z.zone_type_label,
            zone_level         = z.zone_level,
            color              = z.color,
            constituent_pcodes = z.constituent_pcodes,
            is_zone            = true,
        }
        -- recurse into child zones
        local sub = build_children(z.zone_pcode, depth + 1)
        if sub and #sub > 0 then node.children = sub end
        table.insert(children, node)
    end

    if #children == 0 then return nil end
    return children
end

-- ---------------------------------------------------------------------------
-- Get tenant metadata
-- ---------------------------------------------------------------------------
local tenant, _ = db.get_tenant(tenant_id)
local country_pcode = (tenant and tenant.country_code) or ""

-- ---------------------------------------------------------------------------
-- Assemble states list
-- ---------------------------------------------------------------------------
local states = {}
local lga_count  = 0
local zone_count = 0

for _, s in ipairs(states_list) do
    local lgas  = lgas_by_state[s.pcode]  or {}
    local zones = zones_by_state[s.pcode] or {}
    lga_count  = lga_count  + #lgas
    zone_count = zone_count + #zones

    local state_entry = {
        pcode       = s.pcode,
        name        = s.name,
        level       = 1,
        level_label = s.level_label,
        area_sqkm   = tonumber(s.area_sqkm),
        center_lat  = tonumber(s.center_lat),
        center_lon  = tonumber(s.center_lon),
        lgas        = lgas,   -- backward compat: ungrouped adm2 LGAs
    }
    if #zones > 0 then
        state_entry.zones = zones  -- backward compat: level-1 zones
    end

    -- new: recursive children tree (adm3+ features + nested zones)
    local children = build_children(s.pcode, 1)
    if children then
        state_entry.children = children
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
ngx.header["Vary"]          = "X-Tenant-ID"
ngx.header["X-Cache"]       = "MISS"
ngx.print(body)
