-- serve-hierarchy.lua
-- GET /boundaries/hierarchy[?raw=1]
-- ?raw=1: returns pure adm_features tree (for left panel in HierarchyEditorView)
-- default: returns geo_hierarchy_nodes tree + ungrouped LGAs

local cjson = require("cjson.safe")
local db    = require("boundary-db")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)
local is_raw    = (ngx.var.arg_raw == "1")

local cache_suffix = is_raw and ":raw" or ""
local cache_key    = "h:" .. tenant_id .. cache_suffix
local tc_key       = is_raw and "hierarchy_raw" or "hierarchy"

local hierarchy_cache = ngx.shared.hierarchy_cache

local function send_cached(body, x_cache)
    ngx.header["Content-Type"]  = "application/json"
    ngx.header["Cache-Control"] = "public, max-age=86400"
    ngx.header["Vary"]          = "X-Tenant-ID"
    ngx.header["X-Cache"]       = x_cache
    ngx.print(body)
end

-- L1: ngx.shared (in-memory, clears on restart)
if hierarchy_cache then
    local cached = hierarchy_cache:get(cache_key)
    if cached then send_cached(cached, "HIT"); return end
end

-- L2: tenant_cache in Postgres (persistent across restarts)
local l2 = db.get_tenant_cache(tenant_id, tc_key)
if l2 then
    if hierarchy_cache then hierarchy_cache:set(cache_key, l2, 86400) end
    send_cached(l2, "L2-HIT")
    return
end

-- Fetch adm_features (used by both raw and main branches)
local adm_rows, err1 = db.get_hierarchy_adm_features(tenant_id)

if err1 then
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error="Database error", code="DB_ERROR", detail=err1 }))
    return
end

-- ---------------------------------------------------------------------------
-- Index adm_features
-- ---------------------------------------------------------------------------
local adm_by_pcode       = {}
local adm3plus_by_parent = {}
local adm2_by_parent     = {}
local states_list        = {}

for _, a in ipairs(adm_rows or {}) do
    adm_by_pcode[a.pcode] = a
    local lvl = tonumber(a.adm_level)
    if lvl == 1 then
        table.insert(states_list, a)
    elseif lvl == 2 then
        if a.parent_pcode then
            local list = adm2_by_parent[a.parent_pcode] or {}
            table.insert(list, a)
            adm2_by_parent[a.parent_pcode] = list
        end
    elseif lvl >= 3 then
        if a.parent_pcode then
            local list = adm3plus_by_parent[a.parent_pcode] or {}
            table.insert(list, a)
            adm3plus_by_parent[a.parent_pcode] = list
        end
    end
end

-- Get tenant metadata
local tenant, _ = db.get_tenant(tenant_id)
local country_pcode = (tenant and tenant.country_code) or ""
local country_name  = (tenant and tenant.country_name) or ""

-- ===========================================================================
-- ?raw=1 branch — pure adm_features, no geo_hierarchy_nodes
-- ===========================================================================
if is_raw then
    -- Simple recursive adm3+ children builder
    local function build_raw_children(parent_pcode, depth)
        if depth > 8 then return nil end
        local children = {}
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
            local sub = build_raw_children(a.pcode, depth + 1)
            if sub and #sub > 0 then node.children = sub end
            table.insert(children, node)
        end
        -- adm2 features when no adm3+ at this level
        for _, a in ipairs(adm2_by_parent[parent_pcode] or {}) do
            local node = {
                pcode       = a.pcode,
                name        = a.name,
                level       = 2,
                level_label = a.level_label,
                area_sqkm   = tonumber(a.area_sqkm),
                center_lat  = tonumber(a.center_lat),
                center_lon  = tonumber(a.center_lon),
            }
            local sub = build_raw_children(a.pcode, depth + 1)
            if sub and #sub > 0 then node.children = sub end
            table.insert(children, node)
        end
        if #children == 0 then return nil end
        return children
    end

    local states = {}
    for _, s in ipairs(states_list) do
        local adm2s = {}
        for _, a in ipairs(adm2_by_parent[s.pcode] or {}) do
            local adm2_entry = {
                pcode       = a.pcode,
                name        = a.name,
                level_label = a.level_label,
                area_sqkm   = tonumber(a.area_sqkm),
                center_lat  = tonumber(a.center_lat),
                center_lon  = tonumber(a.center_lon),
            }
            -- Attach adm3+ children (e.g. sectors under districts for Rwanda)
            local sub = build_raw_children(a.pcode, 2)
            if sub and #sub > 0 then adm2_entry.children = sub end
            table.insert(adm2s, adm2_entry)
        end
        local state_entry = {
            pcode      = s.pcode,
            name       = s.name,
            level      = 1,
            area_sqkm  = tonumber(s.area_sqkm),
            center_lat = tonumber(s.center_lat),
            center_lon = tonumber(s.center_lon),
            adm2s      = adm2s,
        }
        local sub = build_raw_children(s.pcode, 1)
        if sub and #sub > 0 then state_entry.children = sub end
        table.insert(states, state_entry)
    end

    local response = {
        raw         = true,
        pcode       = country_pcode,
        name        = country_name,
        state_count = #states,
        states      = states,
    }

    local body = cjson.encode(response)
    if hierarchy_cache then hierarchy_cache:set(cache_key, body, 86400) end
    db.set_tenant_cache(tenant_id, tc_key, body)
    send_cached(body, "MISS")
    return
end

-- ===========================================================================
-- Main branch — geo_hierarchy_nodes tree
-- ===========================================================================

local nodes_rows, err2 = db.get_geo_nodes(tenant_id)

if err2 then
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error="Database error", code="DB_ERROR", detail=err2 }))
    return
end

-- ---------------------------------------------------------------------------
-- Index geo_hierarchy_nodes by parent key
-- Root nodes (parent_id IS NULL) -> key = "state:{state_pcode}"
-- Child nodes                    -> key = "id:{parent_id}"
-- ---------------------------------------------------------------------------
local nodes_by_parent = {}  -- key -> [node, ...]
local assigned_pcodes = {}  -- pcode -> true (LGAs assigned to any node)

for _, n in ipairs(nodes_rows or {}) do
    local key
    if n.parent_id then
        key = "id:" .. tostring(n.parent_id)
    else
        key = "state:" .. (n.state_pcode or "")
    end
    nodes_by_parent[key] = nodes_by_parent[key] or {}
    table.insert(nodes_by_parent[key], n)

    -- Track assigned LGA pcodes
    for p in (n.constituent_pcodes or ""):gmatch("[^,]+") do
        assigned_pcodes[p] = true
    end
end

-- ---------------------------------------------------------------------------
-- adm3+ children for LGAs (forward-declared for mutual recursion)
-- ---------------------------------------------------------------------------
local build_adm_children
build_adm_children = function(parent_pcode, depth)
    if depth > 10 then return nil end
    local children = {}
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
        local sub = build_adm_children(a.pcode, depth + 1)
        if sub and #sub > 0 then node.children = sub end
        table.insert(children, node)
    end
    if #children == 0 then return nil end
    return children
end

-- ---------------------------------------------------------------------------
-- Recursive geo_hierarchy_nodes tree builder
-- ---------------------------------------------------------------------------
local build_node_children
build_node_children = function(parent_key, depth)
    if depth > 10 then return nil end
    local children = {}

    for _, n in ipairs(nodes_by_parent[parent_key] or {}) do
        local pcodes = {}
        for p in (n.constituent_pcodes or ""):gmatch("[^,]+") do
            table.insert(pcodes, p)
        end

        local node = {
            id                 = tonumber(n.id),
            pcode              = n.pcode,
            name               = n.name,
            color              = n.color,
            level_order        = tonumber(n.level_order),
            level_label        = n.level_label,
            area_sqkm          = tonumber(n.area_sqkm),
            center_lat         = tonumber(n.center_lat),
            center_lon         = tonumber(n.center_lon),
            constituent_pcodes = pcodes,
            is_geo_node        = true,
        }

        local sub = build_node_children("id:" .. tostring(n.id), depth + 1)
        if sub and #sub > 0 then
            node.children = sub
        else
            -- Leaf node: attach constituent adm2 features as children for grouping nodes
            -- (e.g. a region containing multiple sub-counties). Skip for adm3+ constituents
            -- (sectors, wards, parishes) — the geo_node itself IS the boundary, so nesting
            -- the raw adm_features record underneath creates a redundant duplicate row.
            local adm2_children = {}
            for _, pcode in ipairs(pcodes) do
                local adm2 = adm_by_pcode[pcode]
                if adm2 and tonumber(adm2.adm_level) <= 2 then
                    local adm2_node = {
                        pcode       = adm2.pcode,
                        name        = adm2.name,
                        level       = tonumber(adm2.adm_level),
                        level_label = adm2.level_label,
                        area_sqkm   = tonumber(adm2.area_sqkm),
                        center_lat  = tonumber(adm2.center_lat),
                        center_lon  = tonumber(adm2.center_lon),
                    }
                    local adm_sub = build_adm_children(adm2.pcode, depth + 2)
                    if adm_sub and #adm_sub > 0 then adm2_node.children = adm_sub end
                    table.insert(adm2_children, adm2_node)
                end
            end
            if #adm2_children > 0 then node.children = adm2_children end
        end

        table.insert(children, node)
    end

    if #children == 0 then return nil end
    return children
end

-- ---------------------------------------------------------------------------
-- Assemble states
-- ---------------------------------------------------------------------------
local states    = {}
local adm2_count = 0

for _, s in ipairs(states_list) do
    -- Ungrouped adm2 features: under this state NOT assigned to any geo node
    local adm2s = {}
    for _, a in ipairs(adm2_by_parent[s.pcode] or {}) do
        if not assigned_pcodes[a.pcode] then
            adm2_count = adm2_count + 1
            table.insert(adm2s, {
                pcode       = a.pcode,
                name        = a.name,
                level_label = a.level_label,
                area_sqkm   = tonumber(a.area_sqkm),
                center_lat  = tonumber(a.center_lat),
                center_lon  = tonumber(a.center_lon),
            })
        end
    end

    local state_entry = {
        pcode      = s.pcode,
        name       = s.name,
        level      = 1,
        level_label = s.level_label,
        area_sqkm  = tonumber(s.area_sqkm),
        center_lat = tonumber(s.center_lat),
        center_lon = tonumber(s.center_lon),
        adm2s      = adm2s,
    }

    -- Geo hierarchy nodes under this state
    local node_children = build_node_children("state:" .. s.pcode, 1)
    if node_children then
        state_entry.children = node_children
    else
        -- Fallback: show adm3+ under state if no geo nodes
        local adm_sub = build_adm_children(s.pcode, 1)
        if adm_sub then state_entry.children = adm_sub end
    end

    table.insert(states, state_entry)
end

local response = {
    pcode       = country_pcode,
    name        = country_name,
    source      = "PostGIS",
    state_count = #states,
    adm2_count  = adm2_count,
    states      = states,
}

local body = cjson.encode(response)
if hierarchy_cache then hierarchy_cache:set(cache_key, body, 86400) end
db.set_tenant_cache(tenant_id, tc_key, body)
send_cached(body, "MISS")
