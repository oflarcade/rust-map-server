-- admin-territories.lua
-- Manage which admin features (LGAs/states) are in a tenant's operational scope.
--
-- Routes:
--   GET    /admin/territories         -> list in-scope + available
--   POST   /admin/territories         -> add pcodes to tenant_scope
--   DELETE /admin/territories/:pcode  -> remove pcode from tenant_scope

local cjson = require("cjson.safe")
local pg    = require("pg-pool")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)
local method    = ngx.req.get_method()
local uri       = ngx.var.uri

-- Extract pcode from DELETE /admin/territories/:pcode
local del_pcode = uri:match("^/admin/territories/(.+)$")

local function invalidate_caches()
    local hierarchy_cache = ngx.shared.hierarchy_cache
    if hierarchy_cache then hierarchy_cache:delete("h:" .. tenant_id) end
    local region_cache = ngx.shared.region_cache
    if region_cache then region_cache:flush_all() end
    -- L2 persistent cache in Postgres must also be cleared.
    pg.exec("DELETE FROM tenant_cache WHERE tenant_id = $1", {tenant_id})
end

-- ---------------------------------------------------------------------------
-- GET /admin/territories
-- ---------------------------------------------------------------------------
local function list_territories()
    -- In-scope features with child count
    local in_scope, err1 = pg.exec([[
        SELECT a.pcode, a.name, a.adm_level,
               (SELECT COUNT(*) FROM adm_features c WHERE c.parent_pcode = a.pcode) AS children_count
        FROM adm_features a
        JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
        ORDER BY a.adm_level, a.name
    ]], {tenant_id})

    if err1 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err1 }))
        return
    end

    -- Available LGAs (adm_level=2) not yet in scope for this tenant's country
    local available, err2 = pg.exec([[
        SELECT a.pcode, a.name, a.adm_level, a.parent_pcode, s.name AS parent_name
        FROM adm_features a
        JOIN adm_features s ON s.pcode = a.parent_pcode
        WHERE a.country_code = (SELECT country_code FROM tenants WHERE tenant_id = $1)
          AND a.adm_level = 2
          AND a.pcode NOT IN (SELECT pcode FROM tenant_scope WHERE tenant_id = $1)
        ORDER BY s.name, a.name
    ]], {tenant_id})

    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err2 }))
        return
    end

    local in_scope_list = {}
    for _, row in ipairs(in_scope or {}) do
        table.insert(in_scope_list, {
            pcode          = row.pcode,
            name           = row.name,
            adm_level      = tonumber(row.adm_level),
            children_count = tonumber(row.children_count) or 0,
        })
    end

    local available_list = {}
    for _, row in ipairs(available or {}) do
        table.insert(available_list, {
            pcode        = row.pcode,
            name         = row.name,
            adm_level    = tonumber(row.adm_level),
            parent_pcode = row.parent_pcode,
            parent_name  = row.parent_name,
        })
    end

    ngx.header["Content-Type"] = "application/json"
    if #in_scope_list == 0 then in_scope_list = cjson.empty_array end
    if #available_list == 0 then available_list = cjson.empty_array end
    ngx.say(cjson.encode({ in_scope = in_scope_list, available = available_list }))
end

-- ---------------------------------------------------------------------------
-- POST /admin/territories  — add pcodes to tenant_scope
-- Body: { "pcodes": ["NG018001", "NG018002"] }
-- ---------------------------------------------------------------------------
local function add_territories()
    ngx.req.read_body()
    local body_str = ngx.req.get_body_data()
    if not body_str then
        ngx.status = 400
        ngx.say('{"error":"Empty request body","code":"MISSING_BODY"}')
        return
    end

    local body, decode_err = cjson.decode(body_str)
    if not body or not body.pcodes or type(body.pcodes) ~= "table" or #body.pcodes == 0 then
        ngx.status = 400
        ngx.say('{"error":"pcodes array is required","code":"MISSING_FIELD"}')
        return
    end

    local pcodes = body.pcodes
    local pcodes_literal = "{" .. table.concat(pcodes, ",") .. "}"

    -- Only insert pcodes that exist in adm_features for this tenant's country
    local _, err = pg.exec([[
        INSERT INTO tenant_scope (tenant_id, pcode)
        SELECT $1, a.pcode
        FROM adm_features a
        WHERE a.pcode = ANY($2::text[])
          AND a.country_code = (SELECT country_code FROM tenants WHERE tenant_id = $1)
        ON CONFLICT DO NOTHING
    ]], {tenant_id, pcodes_literal})

    if err then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err }))
        return
    end

    -- Auto-include parent states for any scoped LGAs so hierarchy has adm1 anchors.
    local _, err_parent = pg.exec([[
        INSERT INTO tenant_scope (tenant_id, pcode)
        SELECT DISTINCT $1, a.parent_pcode
        FROM adm_features a
        WHERE a.pcode = ANY($2::text[])
          AND a.adm_level = 2
          AND a.parent_pcode IS NOT NULL
          AND a.country_code = (SELECT country_code FROM tenants WHERE tenant_id = $1)
        ON CONFLICT DO NOTHING
    ]], {tenant_id, pcodes_literal})

    if err_parent then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err_parent }))
        return
    end

    -- Invalidate caches
    invalidate_caches()

    ngx.status = 201
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ added = #pcodes }))
end

-- ---------------------------------------------------------------------------
-- DELETE /admin/territories/:pcode
-- ---------------------------------------------------------------------------
local function remove_territory(pcode)
    -- Check whether any zone uses this pcode as a constituent
    local zone_check, err0 = pg.exec([[
        SELECT COUNT(*) AS cnt FROM zones
        WHERE tenant_id = $1 AND $2::text = ANY(constituent_pcodes)
    ]], {tenant_id, pcode})

    if err0 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err0 }))
        return
    end

    local in_zone = tonumber((zone_check and zone_check[1] and zone_check[1].cnt) or 0)
    if in_zone > 0 then
        ngx.status = 409
        ngx.say(cjson.encode({
            error      = "Cannot remove: pcode is used in one or more zones",
            code       = "PCODE_IN_USE",
            zone_count = in_zone,
        }))
        return
    end

    local _, err = pg.exec(
        "DELETE FROM tenant_scope WHERE tenant_id = $1 AND pcode = $2",
        {tenant_id, pcode}
    )
    if err then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err }))
        return
    end

    -- Invalidate caches
    invalidate_caches()

    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"deleted":true}')
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------
ngx.header["Content-Type"] = "application/json"

if method == "GET" and not del_pcode then
    list_territories()
elseif method == "POST" and not del_pcode then
    add_territories()
elseif method == "DELETE" and del_pcode then
    remove_territory(del_pcode)
else
    ngx.status = 405
    ngx.say('{"error":"Method not allowed","code":"METHOD_NOT_ALLOWED"}')
end
