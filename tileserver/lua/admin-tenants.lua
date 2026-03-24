-- admin-tenants.lua
-- Tenant management API (list + create).
--
-- Routes:
--   GET  /admin/tenants  -> list all tenants
--   POST /admin/tenants  -> create a new tenant

local cjson     = require("cjson.safe")
local pg        = require("pg-pool")
local router    = require("tenant-router")
local normalize = require("tile-source-normalize")

local method = ngx.req.get_method()

-- ---------------------------------------------------------------------------
-- GET /admin/tenants
-- ---------------------------------------------------------------------------
local function list_tenants()
    local rows, err = pg.exec([[
        SELECT tenant_id, country_code, country_name,
               tile_source, boundary_source, hdx_prefix
        FROM tenants
        ORDER BY tenant_id
    ]], {})

    if err then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err }))
        return
    end

    local tenants = {}
    for _, row in ipairs(rows or {}) do
        table.insert(tenants, {
            tenant_id      = tonumber(row.tenant_id),
            country_code   = row.country_code,
            country_name   = row.country_name,
            tile_source    = row.tile_source,
            boundary_source = row.boundary_source,
            hdx_prefix     = row.hdx_prefix,
        })
    end
    if #tenants == 0 then tenants = cjson.empty_array end

    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ tenants = tenants }))
end

-- ---------------------------------------------------------------------------
-- POST /admin/tenants
-- Body: { tenant_id, country_code, country_name, tile_source, boundary_source, hdx_prefix? }
-- ---------------------------------------------------------------------------
local function create_tenant()
    ngx.req.read_body()
    local body_str = ngx.req.get_body_data()
    if not body_str then
        ngx.status = 400
        ngx.say('{"error":"Empty request body","code":"MISSING_BODY"}')
        return
    end

    local body, decode_err = cjson.decode(body_str)
    if not body then
        ngx.status = 400
        ngx.say('{"error":"Invalid JSON","code":"INVALID_JSON","detail":"' .. (decode_err or "") .. '"}')
        return
    end

    local tenant_id     = tonumber(body.tenant_id)
    local country_code  = body.country_code
    local country_name  = body.country_name
    local tile_source   = body.tile_source
    local boundary_source = normalize.normalize_boundary_source(body.boundary_source)
    local hdx_prefix    = body.hdx_prefix or ""

    if not tenant_id or not country_code or not tile_source then
        ngx.status = 400
        ngx.say('{"error":"tenant_id, country_code, and tile_source are required","code":"MISSING_FIELD"}')
        return
    end

    local result, err = pg.exec([[
        INSERT INTO tenants (tenant_id, country_code, country_name, tile_source, boundary_source, hdx_prefix)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (tenant_id) DO UPDATE SET
            country_code    = EXCLUDED.country_code,
            country_name    = EXCLUDED.country_name,
            tile_source     = EXCLUDED.tile_source,
            boundary_source = EXCLUDED.boundary_source,
            hdx_prefix      = EXCLUDED.hdx_prefix
        RETURNING tenant_id, country_code, country_name, tile_source, boundary_source, hdx_prefix
    ]], {tenant_id, country_code, country_name, tile_source, boundary_source, hdx_prefix})

    if err then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", detail = err }))
        return
    end

    -- Invalidate router cache for this tenant so it picks up the new config
    router.invalidate(tenant_id)

    ngx.status = 201
    ngx.header["Content-Type"] = "application/json"
    local row = result and result[1]
    if row then
        ngx.say(cjson.encode({
            tenant_id      = tonumber(row.tenant_id),
            country_code   = row.country_code,
            country_name   = row.country_name,
            tile_source    = row.tile_source,
            boundary_source = row.boundary_source,
            hdx_prefix     = row.hdx_prefix,
        }))
    else
        ngx.say('{"error":"Insert failed","code":"INSERT_FAILED"}')
    end
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------
ngx.header["Content-Type"] = "application/json"

if method == "GET" then
    list_tenants()
elseif method == "POST" then
    create_tenant()
else
    ngx.status = 405
    ngx.say('{"error":"Method not allowed","code":"METHOD_NOT_ALLOWED"}')
end
