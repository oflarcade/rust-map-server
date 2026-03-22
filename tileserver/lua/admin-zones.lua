-- admin-zones.lua
-- Zone CRUD for the admin UI.
-- All operations identify the tenant via X-Tenant-ID header (never request body).
-- Access is restricted by origin whitelist (origin-whitelist.lua runs first).
--
-- Routes (dispatched internally):
--   GET    /admin/zones          -> list_zones(tenant_id)
--   POST   /admin/zones          -> create_zone(tenant_id)
--   PUT    /admin/zones/:zone_id -> update_zone(tenant_id, zone_id)
--   DELETE /admin/zones/:zone_id -> delete_zone(tenant_id, zone_id)

local cjson = require("cjson.safe")
local pg    = require("pg-pool")
local db    = require("boundary-db")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)

local function invalidate_cache()
    local hc = ngx.shared.hierarchy_cache
    if hc then hc:delete("h:" .. tenant_id) end
    local gc = ngx.shared.geojson_cache
    if gc then gc:delete("gj:" .. tenant_id) end
    db.delete_tenant_cache(tenant_id)
end
local method    = ngx.req.get_method()
local uri       = ngx.var.uri
local zone_id   = tonumber(uri:match("^/admin/zones/(%d+)$"))

-- ---------------------------------------------------------------------------
-- GET /admin/zones  — list all zones for this tenant
-- ---------------------------------------------------------------------------
local function list_zones()
    local rows, err = pg.exec([[
        SELECT zone_id, zone_pcode, zone_name, color, parent_pcode,
               zone_type_label, zone_level, children_type,
               array_to_string(constituent_pcodes, ',') AS constituent_pcodes,
               created_at, updated_at, updated_by
        FROM zones
        WHERE tenant_id = $1
        ORDER BY zone_level, zone_name
    ]], {tenant_id})

    if err then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err }))
        return
    end

    local zones = {}
    for _, row in ipairs(rows or {}) do
        local pcodes = {}
        for p in (row.constituent_pcodes or ""):gmatch("[^,]+") do
            table.insert(pcodes, p)
        end
        table.insert(zones, {
            zone_id             = tonumber(row.zone_id),
            zone_pcode          = row.zone_pcode,
            zone_name           = row.zone_name,
            color               = row.color,
            parent_pcode        = row.parent_pcode,
            zone_type_label     = row.zone_type_label,
            zone_level          = tonumber(row.zone_level) or 1,
            children_type       = row.children_type or "lga",
            constituent_pcodes  = pcodes,
            created_at          = row.created_at,
            updated_at          = row.updated_at,
            updated_by          = row.updated_by,
        })
    end

    ngx.header["Content-Type"] = "application/json"
    -- force array encoding even when empty (cjson encodes {} as object by default)
    if #zones == 0 then zones = cjson.empty_array end
    ngx.say(cjson.encode({ tenant_id = tenant_id, zones = zones }))
end

-- ---------------------------------------------------------------------------
-- POST /admin/zones  — create a new zone
-- Body: { zone_name, color, parent_pcode, constituent_pcodes[] }
-- ---------------------------------------------------------------------------
local function create_zone()
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

    local zone_name          = body.zone_name
    local color              = body.color or "#888888"
    local parent_pcode       = body.parent_pcode
    local constituent_pcodes = body.constituent_pcodes
    local zone_type_label    = body.zone_type_label   -- optional
    local zone_level         = tonumber(body.zone_level) or 1
    local children_type      = body.children_type or "lga"
    local explicit_pcode     = body.zone_pcode        -- optional — skip auto-generation
    local updated_by         = body.updated_by        -- optional — auth prep

    if not zone_name or zone_name == "" then
        ngx.status = 400
        ngx.say('{"error":"zone_name is required","code":"MISSING_FIELD"}')
        return
    end
    if not parent_pcode or parent_pcode == "" then
        ngx.status = 400
        ngx.say('{"error":"parent_pcode is required","code":"MISSING_FIELD"}')
        return
    end
    if not constituent_pcodes or #constituent_pcodes == 0 then
        ngx.status = 400
        ngx.say('{"error":"constituent_pcodes must be a non-empty array","code":"MISSING_FIELD"}')
        return
    end
    if children_type ~= "lga" and children_type ~= "zone" then
        ngx.status = 400
        ngx.say('{"error":"children_type must be lga or zone","code":"INVALID_FIELD"}')
        return
    end

    -- Validate constituent pcodes
    local pcodes_literal = "{" .. table.concat(constituent_pcodes, ",") .. "}"
    local valid_check, err0

    if children_type == "zone" then
        -- constituent_pcodes are zone pcodes belonging to this tenant
        valid_check, err0 = pg.exec([[
            SELECT COUNT(*) AS cnt FROM zones
            WHERE tenant_id = $1 AND zone_pcode = ANY($2::text[])
        ]], {tenant_id, pcodes_literal})
    else
        -- constituent_pcodes are adm_features pcodes in tenant scope
        valid_check, err0 = pg.exec([[
            SELECT COUNT(*) AS cnt FROM adm_features a
            JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
            WHERE a.pcode = ANY($2::text[])
        ]], {tenant_id, pcodes_literal})
    end

    if err0 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err0 }))
        return
    end

    local valid_count = tonumber((valid_check and valid_check[1] and valid_check[1].cnt) or 0)
    if valid_count ~= #constituent_pcodes then
        ngx.status = 422
        ngx.say(cjson.encode({
            error    = "One or more constituent_pcodes are invalid for this tenant",
            code     = "INVALID_PCODES",
            expected = #constituent_pcodes,
            found    = valid_count,
        }))
        return
    end

    -- Choose geometry source depending on children_type
    local geom_subquery
    if children_type == "zone" then
        geom_subquery = "(SELECT ST_Multi(ST_Union(geom)) FROM zones WHERE zone_pcode = ANY($5::text[]) AND tenant_id = $2)"
    else
        geom_subquery = "(SELECT ST_Multi(ST_Union(geom)) FROM adm_features WHERE pcode = ANY($5::text[]))"
    end

    -- Generate zone_pcode transactionally (prevents race on concurrent creates)
    -- Format: <parent_pcode>-Z<nn>  e.g. NG025-Z01
    -- If explicit_pcode provided, use it directly.
    local insert_sql
    local insert_params

    if explicit_pcode and explicit_pcode ~= "" then
        insert_sql = [[
            INSERT INTO zones(tenant_id, zone_pcode, zone_name, color, parent_pcode,
                              constituent_pcodes, geom, zone_type_label, zone_level, children_type, updated_by)
            VALUES ($2, $6, $3, $4, $1, $5::text[], ]] .. geom_subquery .. [[,
                    $7, $8, $9, $10)
            RETURNING zone_id, zone_pcode, zone_name, color, parent_pcode,
                      zone_type_label, zone_level, children_type, updated_by,
                      array_to_string(constituent_pcodes, ',') AS constituent_pcodes
        ]]
        insert_params = {parent_pcode, tenant_id, zone_name, color, pcodes_literal,
                         explicit_pcode, zone_type_label, zone_level, children_type, updated_by}
    else
        insert_sql = [[
            WITH next_num AS (
                SELECT COALESCE(MAX(
                    CAST(REGEXP_REPLACE(zone_pcode, '^.*-Z0*', '') AS INTEGER)
                ), 0) + 1 AS n
                FROM zones
                WHERE parent_pcode = $1 AND tenant_id = $2
            ),
            new_zone AS (
                INSERT INTO zones(tenant_id, zone_pcode, zone_name, color, parent_pcode,
                                  constituent_pcodes, geom, zone_type_label, zone_level, children_type, updated_by)
                SELECT
                    $2,
                    $1 || '-Z' || LPAD(n::text, 2, '0'),
                    $3, $4, $1, $5::text[], ]] .. geom_subquery .. [[,
                    $6, $7, $8, $9
                FROM next_num
                RETURNING zone_id, zone_pcode, zone_name, color, parent_pcode,
                          zone_type_label, zone_level, children_type, updated_by,
                          array_to_string(constituent_pcodes, ',') AS constituent_pcodes
            )
            SELECT * FROM new_zone
        ]]
        insert_params = {parent_pcode, tenant_id, zone_name, color, pcodes_literal,
                         zone_type_label, zone_level, children_type, updated_by}
    end

    local insert_result, err1 = pg.exec(insert_sql, insert_params)

    if err1 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err1 }))
        return
    end

    invalidate_cache()
    ngx.status = 201
    ngx.header["Content-Type"] = "application/json"
    local created = insert_result and insert_result[1]
    if created then
        local pcodes_out = {}
        for p in (created.constituent_pcodes or ""):gmatch("[^,]+") do
            table.insert(pcodes_out, p)
        end
        ngx.say(cjson.encode({
            zone_id            = tonumber(created.zone_id),
            zone_pcode         = created.zone_pcode,
            zone_name          = created.zone_name,
            color              = created.color,
            parent_pcode       = created.parent_pcode,
            zone_type_label    = created.zone_type_label,
            zone_level         = tonumber(created.zone_level) or 1,
            children_type      = created.children_type or "lga",
            constituent_pcodes = pcodes_out,
        }))
    else
        ngx.say('{"error":"Insert failed","code":"INSERT_FAILED"}')
    end
end

-- ---------------------------------------------------------------------------
-- PUT /admin/zones/:zone_id  — update name, color, or constituent_pcodes
-- Body: { zone_name?, color?, constituent_pcodes? }
-- ---------------------------------------------------------------------------
local function update_zone(zid)
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
        ngx.say('{"error":"Invalid JSON","code":"INVALID_JSON"}')
        return
    end

    -- Verify zone belongs to this tenant
    local owner_check, err_o = pg.exec(
        "SELECT zone_id FROM zones WHERE zone_id = $1 AND tenant_id = $2",
        {zid, tenant_id}
    )
    if err_o then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err_o }))
        return
    end
    if not owner_check or #owner_check == 0 then
        ngx.status = 404
        ngx.say('{"error":"Zone not found or not owned by this tenant","code":"NOT_FOUND"}')
        return
    end

    -- Build dynamic SET clauses
    local sets   = {"updated_at = NOW()"}
    local params = {}
    local idx    = 1

    if body.zone_name then
        table.insert(sets, "zone_name = $" .. idx)
        table.insert(params, body.zone_name)
        idx = idx + 1
    end
    if body.color then
        table.insert(sets, "color = $" .. idx)
        table.insert(params, body.color)
        idx = idx + 1
    end
    if body.zone_type_label ~= nil then
        table.insert(sets, "zone_type_label = $" .. idx)
        table.insert(params, body.zone_type_label)
        idx = idx + 1
    end
    if body.zone_level then
        table.insert(sets, "zone_level = $" .. idx)
        table.insert(params, tonumber(body.zone_level))
        idx = idx + 1
    end
    if body.updated_by ~= nil then
        table.insert(sets, "updated_by = $" .. idx)
        table.insert(params, body.updated_by)
        idx = idx + 1
    end
    if body.constituent_pcodes and #body.constituent_pcodes > 0 then
        local pcodes_literal = "{" .. table.concat(body.constituent_pcodes, ",") .. "}"
        table.insert(sets, "constituent_pcodes = $" .. idx .. "::text[]")
        table.insert(params, pcodes_literal)
        idx = idx + 1
        table.insert(sets, "geom = (SELECT ST_Multi(ST_Union(geom)) FROM adm_features WHERE pcode = ANY($" .. (idx-1) .. "::text[]))")
    end

    table.insert(params, zid)
    local where_idx = idx

    local sql = "UPDATE zones SET " .. table.concat(sets, ", ") ..
                " WHERE zone_id = $" .. where_idx .. " RETURNING zone_id, zone_pcode, zone_name, color"

    local result, err2 = pg.exec(sql, params)
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err2 }))
        return
    end

    invalidate_cache()
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(result and result[1] or {}))
end

-- ---------------------------------------------------------------------------
-- DELETE /admin/zones/:zone_id
-- ---------------------------------------------------------------------------
local function delete_zone(zid)
    -- Verify ownership
    local owner_check, err_o = pg.exec(
        "SELECT zone_id FROM zones WHERE zone_id = $1 AND tenant_id = $2",
        {zid, tenant_id}
    )
    if err_o then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err_o }))
        return
    end
    if not owner_check or #owner_check == 0 then
        ngx.status = 404
        ngx.say('{"error":"Zone not found or not owned by this tenant","code":"NOT_FOUND"}')
        return
    end

    local _, err2 = pg.exec(
        "DELETE FROM zones WHERE zone_id = $1 AND tenant_id = $2",
        {zid, tenant_id}
    )
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err2 }))
        return
    end

    invalidate_cache()
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"deleted":true}')
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------
ngx.header["Content-Type"] = "application/json"

if method == "GET" and not zone_id then
    list_zones()
elseif method == "POST" and not zone_id then
    create_zone()
elseif method == "PUT" and zone_id then
    update_zone(zone_id)
elseif method == "DELETE" and zone_id then
    delete_zone(zone_id)
else
    ngx.status = 405
    ngx.say('{"error":"Method not allowed","code":"METHOD_NOT_ALLOWED"}')
end
