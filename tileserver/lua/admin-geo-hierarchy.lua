-- admin-geo-hierarchy.lua
-- CRUD for geo_hierarchy_levels and geo_hierarchy_nodes.
-- All operations identify the tenant via X-Tenant-ID header.
-- Access restricted by origin-whitelist.lua (runs first).
--
-- Level routes:
--   GET    /admin/geo-hierarchy/levels          -> list levels
--   POST   /admin/geo-hierarchy/levels          -> create level
--   PUT    /admin/geo-hierarchy/levels/:id      -> update level
--   DELETE /admin/geo-hierarchy/levels/:id      -> delete level (cascades to nodes)
--
-- Node routes:
--   GET    /admin/geo-hierarchy/nodes           -> full node list
--   POST   /admin/geo-hierarchy/nodes           -> create node (auto-pcode, geom)
--   PUT    /admin/geo-hierarchy/nodes/:id       -> update node (name/color/pcodes)
--   DELETE /admin/geo-hierarchy/nodes/:id       -> delete node (cascade)

local cjson = require("cjson.safe")
local pg    = require("pg-pool")
local db    = require("boundary-db")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)
local method    = ngx.req.get_method()
local uri       = ngx.var.uri

-- Dispatch based on URI path segments
-- /admin/geo-hierarchy/levels[/:id]
-- /admin/geo-hierarchy/nodes[/:id]
local resource, res_id = uri:match("^/admin/geo%-hierarchy/([^/]+)/?(%d*)$")
res_id = tonumber(res_id)

ngx.header["Content-Type"] = "application/json"

-- ---------------------------------------------------------------------------
-- Helper: invalidate hierarchy cache for tenant
-- ---------------------------------------------------------------------------
local function invalidate_cache()
    -- L1: ngx.shared (in-memory)
    local hc = ngx.shared.hierarchy_cache
    if hc then
        hc:delete("h:" .. tenant_id)
        hc:delete("h:" .. tenant_id .. ":raw")
    end
    local gc = ngx.shared.geojson_cache
    if gc then gc:delete("gj:" .. tenant_id) end
    -- region_cache has no prefix-scan; hierarchy edits are infrequent admin ops
    local rc = ngx.shared.region_cache
    if rc then rc:flush_all() end
    -- L2: tenant_cache in Postgres (persistent)
    db.delete_tenant_cache(tenant_id)
end

-- ---------------------------------------------------------------------------
-- Helper: cascade-recompute constituent_pcodes + geom up the ancestor chain
-- from a given node id (bottom-up).
-- ---------------------------------------------------------------------------
local function cascade_ancestors(start_node_id)
    local current_id = start_node_id
    local MAX_DEPTH = 10
    for _ = 1, MAX_DEPTH do
        -- Get parent_id of current node
        local pr, err = pg.exec(
            "SELECT parent_id FROM geo_hierarchy_nodes WHERE id = $1 AND tenant_id = $2",
            {current_id, tenant_id}
        )
        if err then return err end
        if not pr or #pr == 0 then break end
        local pid = pr[1].parent_id
        if not pid or pid == ngx.null then break end

        -- Recompute ancestor's constituent_pcodes and geom from its direct children
        local _, err2 = pg.exec([[
            WITH child_pcodes AS (
                SELECT ARRAY(
                    SELECT DISTINCT UNNEST(constituent_pcodes)
                    FROM geo_hierarchy_nodes
                    WHERE parent_id = $1 AND constituent_pcodes IS NOT NULL
                ) AS pcodes
            ),
            geom_data AS (
                SELECT ST_MakeValid(ST_Multi(ST_Union(a.geom))) AS g
                FROM adm_features a, child_pcodes cp
                WHERE a.pcode = ANY(cp.pcodes)
                  AND cardinality(cp.pcodes) > 0
            )
            UPDATE geo_hierarchy_nodes SET
                constituent_pcodes = (SELECT pcodes FROM child_pcodes),
                geom = (SELECT g FROM geom_data),
                area_sqkm = (SELECT ROUND((ABS(ST_Area(g::geography)) / 1000000.0)::numeric, 2)
                             FROM geom_data),
                center_lat = (SELECT ROUND(ST_Y(ST_Centroid(g))::numeric, 6) FROM geom_data),
                center_lon = (SELECT ROUND(ST_X(ST_Centroid(g))::numeric, 6) FROM geom_data),
                updated_at = NOW()
            WHERE id = $1
        ]], {pid})
        if err2 then return err2 end

        current_id = pid
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: parse + validate JSON body
-- ---------------------------------------------------------------------------
local function parse_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw or raw == "" then
        ngx.status = 400
        ngx.say('{"error":"Empty request body","code":"MISSING_BODY"}')
        return nil
    end
    local body, err = cjson.decode(raw)
    if not body then
        ngx.status = 400
        ngx.say(cjson.encode({error="Invalid JSON", code="INVALID_JSON", detail=err}))
        return nil
    end
    return body
end

-- ---------------------------------------------------------------------------
-- Helper: format a node row for response
-- ---------------------------------------------------------------------------
local function format_node(row)
    local pcodes = {}
    for p in (row.constituent_pcodes or ""):gmatch("[^,]+") do
        table.insert(pcodes, p)
    end
    return {
        id                 = tonumber(row.id),
        tenant_id          = tenant_id,
        parent_id          = tonumber(row.parent_id),
        state_pcode        = row.state_pcode,
        level_id           = tonumber(row.level_id),
        pcode              = row.pcode,
        name               = row.name,
        color              = row.color,
        constituent_pcodes = pcodes,
        area_sqkm          = row.area_sqkm and tonumber(row.area_sqkm),
        center_lat         = row.center_lat and tonumber(row.center_lat),
        center_lon         = row.center_lon and tonumber(row.center_lon),
        created_at         = row.created_at,
        updated_at         = row.updated_at,
    }
end

-- ===========================================================================
-- LEVELS
-- ===========================================================================

local function list_levels()
    local rows, err = pg.exec([[
        SELECT id, level_order, level_label, level_code
        FROM geo_hierarchy_levels
        WHERE tenant_id = $1
        ORDER BY level_order
    ]], {tenant_id})
    if err then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err}))
        return
    end
    local levels = {}
    for _, r in ipairs(rows or {}) do
        table.insert(levels, {
            id          = tonumber(r.id),
            tenant_id   = tenant_id,
            level_order = tonumber(r.level_order),
            level_label = r.level_label,
            level_code  = r.level_code,
        })
    end
    if #levels == 0 then levels = cjson.empty_array end
    ngx.say(cjson.encode({tenant_id = tenant_id, levels = levels}))
end

local function list_level_labels()
    local labels, err = db.get_level_labels_for_tenant(tenant_id)
    if err then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err}))
        return
    end
    if not labels or #labels == 0 then labels = cjson.empty_array end
    ngx.say(cjson.encode({tenant_id = tenant_id, labels = labels}))
end

local function create_level()
    local body = parse_body()
    if not body then return end

    local level_order = tonumber(body.level_order)
    local level_label = body.level_label
    local level_code  = body.level_code

    if not level_order or not level_label or level_label == "" or
       not level_code  or level_code  == "" then
        ngx.status = 400
        ngx.say('{"error":"level_order, level_label, level_code are required","code":"MISSING_FIELD"}')
        return
    end

    local result, err = pg.exec([[
        INSERT INTO geo_hierarchy_levels(tenant_id, level_order, level_label, level_code)
        VALUES ($1, $2, $3, $4)
        RETURNING id, level_order, level_label, level_code
    ]], {tenant_id, level_order, level_label, level_code})

    if err then
        ngx.status = err:find("unique") and 409 or 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err}))
        return
    end

    ngx.status = 201
    local r = result and result[1]
    if r then
        ngx.say(cjson.encode({
            id          = tonumber(r.id),
            tenant_id   = tenant_id,
            level_order = tonumber(r.level_order),
            level_label = r.level_label,
            level_code  = r.level_code,
        }))
    end
end

local function update_level(lid)
    local body = parse_body()
    if not body then return end

    -- ownership check
    local chk, err0 = pg.exec(
        "SELECT id FROM geo_hierarchy_levels WHERE id = $1 AND tenant_id = $2",
        {lid, tenant_id}
    )
    if err0 then ngx.status=502; ngx.say(cjson.encode({error="DB error",code="DB_ERROR",detail=err0})); return end
    if not chk or #chk == 0 then
        ngx.status = 404
        ngx.say('{"error":"Level not found","code":"NOT_FOUND"}')
        return
    end

    local sets   = {}
    local params = {}
    local idx    = 1

    if body.level_order then
        table.insert(sets, "level_order = $" .. idx); table.insert(params, tonumber(body.level_order)); idx=idx+1
    end
    if body.level_label then
        table.insert(sets, "level_label = $" .. idx); table.insert(params, body.level_label); idx=idx+1
    end
    if body.level_code then
        table.insert(sets, "level_code = $" .. idx); table.insert(params, body.level_code); idx=idx+1
    end

    if #sets == 0 then
        ngx.status = 400
        ngx.say('{"error":"No fields to update","code":"MISSING_FIELD"}')
        return
    end

    table.insert(params, lid)
    local sql = "UPDATE geo_hierarchy_levels SET " .. table.concat(sets, ", ") ..
                " WHERE id = $" .. idx ..
                " RETURNING id, level_order, level_label, level_code"

    local result, err2 = pg.exec(sql, params)
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err2}))
        return
    end

    local r = result and result[1]
    if r then
        ngx.say(cjson.encode({
            id          = tonumber(r.id),
            tenant_id   = tenant_id,
            level_order = tonumber(r.level_order),
            level_label = r.level_label,
            level_code  = r.level_code,
        }))
    end
end

local function delete_level(lid)
    local chk, err0 = pg.exec(
        "SELECT id FROM geo_hierarchy_levels WHERE id = $1 AND tenant_id = $2",
        {lid, tenant_id}
    )
    if err0 then ngx.status=502; ngx.say(cjson.encode({error="DB error",code="DB_ERROR",detail=err0})); return end
    if not chk or #chk == 0 then
        ngx.status = 404
        ngx.say('{"error":"Level not found","code":"NOT_FOUND"}')
        return
    end

    -- Delete all nodes at this level first (level_id FK has no CASCADE)
    local _, err_nodes = pg.exec(
        "DELETE FROM geo_hierarchy_nodes WHERE level_id = $1 AND tenant_id = $2",
        {lid, tenant_id}
    )
    if err_nodes then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err_nodes}))
        return
    end

    local _, err2 = pg.exec(
        "DELETE FROM geo_hierarchy_levels WHERE id = $1 AND tenant_id = $2",
        {lid, tenant_id}
    )
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err2}))
        return
    end

    invalidate_cache()
    ngx.say('{"deleted":true}')
end

-- ===========================================================================
-- NODES
-- ===========================================================================

local function list_nodes()
    local rows, err = pg.exec([[
        SELECT n.id, n.parent_id, n.state_pcode, n.level_id, n.pcode, n.name, n.color,
               array_to_string(n.constituent_pcodes, ',') AS constituent_pcodes,
               n.area_sqkm, n.center_lat, n.center_lon,
               n.created_at, n.updated_at,
               l.level_order, l.level_label
        FROM geo_hierarchy_nodes n
        JOIN geo_hierarchy_levels l ON l.id = n.level_id
        WHERE n.tenant_id = $1
        ORDER BY l.level_order, n.name
    ]], {tenant_id})

    if err then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err}))
        return
    end

    local nodes = {}
    for _, r in ipairs(rows or {}) do
        local n = format_node(r)
        n.level_order = tonumber(r.level_order)
        n.level_label = r.level_label
        table.insert(nodes, n)
    end
    if #nodes == 0 then nodes = cjson.empty_array end
    ngx.say(cjson.encode({tenant_id = tenant_id, nodes = nodes}))
end

local function create_node()
    local body = parse_body()
    if not body then return end

    local level_id   = tonumber(body.level_id)
    local name       = body.name
    local state_pcode = body.state_pcode
    local parent_id  = body.parent_id and tonumber(body.parent_id)
    local color      = body.color  -- may be nil (optional); explicit nparams passed to pg.exec
    local constituent_pcodes = body.constituent_pcodes  -- optional array

    if not level_id or not name or name == "" or not state_pcode or state_pcode == "" then
        ngx.status = 400
        ngx.say('{"error":"level_id, name, state_pcode are required","code":"MISSING_FIELD"}')
        return
    end

    -- Verify level belongs to tenant
    local lv_res, err0 = pg.exec(
        "SELECT level_code FROM geo_hierarchy_levels WHERE id = $1 AND tenant_id = $2",
        {level_id, tenant_id}
    )
    if err0 then ngx.status=502; ngx.say(cjson.encode({error="DB error",code="DB_ERROR",detail=err0})); return end
    if not lv_res or #lv_res == 0 then
        ngx.status = 404
        ngx.say('{"error":"Level not found for this tenant","code":"NOT_FOUND"}')
        return
    end
    local level_code = lv_res[1].level_code

    -- Get parent pcode (or use state_pcode for root nodes)
    local parent_pcode
    if parent_id then
        local pp_res, err1 = pg.exec(
            "SELECT pcode FROM geo_hierarchy_nodes WHERE id = $1 AND tenant_id = $2",
            {parent_id, tenant_id}
        )
        if err1 then ngx.status=502; ngx.say(cjson.encode({error="DB error",code="DB_ERROR",detail=err1})); return end
        if not pp_res or #pp_res == 0 then
            ngx.status = 404
            ngx.say('{"error":"Parent node not found","code":"NOT_FOUND"}')
            return
        end
        parent_pcode = pp_res[1].pcode
    else
        parent_pcode = state_pcode
    end

    -- Build pcodes_literal for SQL
    local pcodes_literal = nil
    if constituent_pcodes and #constituent_pcodes > 0 then
        pcodes_literal = "{" .. table.concat(constituent_pcodes, ",") .. "}"
    end

    -- Use a CTE to atomically generate the pcode and insert
    -- parent_id may be NULL for root nodes
    local parent_id_param = parent_id  -- nil for root nodes; explicit nparams passed to pg.exec below
    local parent_id_cond
    if parent_id then
        parent_id_cond = "parent_id = " .. parent_id
    else
        parent_id_cond = "parent_id IS NULL AND state_pcode = '" .. state_pcode:gsub("'","''") .. "'"
    end

    -- Build insert SQL with CTE for atomic pcode generation
    local insert_sql
    local insert_params

    if pcodes_literal then
        insert_sql = string.format([[
            WITH seq_cte AS (
                SELECT COALESCE(MAX(
                    CAST(REGEXP_REPLACE(pcode, '^.*-]] .. level_code .. [[0*', '') AS INTEGER)
                ), 0) + 1 AS seq
                FROM geo_hierarchy_nodes
                WHERE %s
                  AND pcode ~ ('.*-]] .. level_code .. [[\d+$')
            ),
            geom_cte AS (
                SELECT ST_MakeValid(ST_Multi(ST_Union(a.geom))) AS g
                FROM adm_features a WHERE a.pcode = ANY($5::text[])
            ),
            geom_metrics AS (
                SELECT g,
                       ROUND((ABS(ST_Area(g::geography)) / 1000000.0)::numeric, 2) AS area,
                       ROUND(ST_Y(ST_Centroid(g))::numeric, 6) AS clat,
                       ROUND(ST_X(ST_Centroid(g))::numeric, 6) AS clon
                FROM geom_cte
            )
            INSERT INTO geo_hierarchy_nodes(tenant_id, parent_id, state_pcode, level_id, pcode, name, color,
                                            constituent_pcodes, geom, area_sqkm, center_lat, center_lon)
            SELECT $1, $2, $3, $4,
                   $6 || '-' || ']] .. level_code .. [[' || LPAD(seq::text, 3, '0'),
                   $7, $8,
                   $5::text[],
                   g, area, clat, clon
            FROM seq_cte, geom_metrics
            RETURNING id, parent_id, state_pcode, level_id, pcode, name, color,
                      array_to_string(constituent_pcodes, ',') AS constituent_pcodes,
                      area_sqkm, center_lat, center_lon, created_at, updated_at
        ]], parent_id_cond)
        insert_params = {tenant_id, parent_id_param, state_pcode, level_id,
                         pcodes_literal, parent_pcode, name, color}
        insert_params.n = 8
    else
        insert_sql = string.format([[
            WITH seq_cte AS (
                SELECT COALESCE(MAX(
                    CAST(REGEXP_REPLACE(pcode, '^.*-]] .. level_code .. [[0*', '') AS INTEGER)
                ), 0) + 1 AS seq
                FROM geo_hierarchy_nodes
                WHERE %s
                  AND pcode ~ ('.*-]] .. level_code .. [[\d+$')
            )
            INSERT INTO geo_hierarchy_nodes(tenant_id, parent_id, state_pcode, level_id, pcode, name, color)
            SELECT $1, $2, $3, $4,
                   $5 || '-' || ']] .. level_code .. [[' || LPAD(seq::text, 3, '0'),
                   $6, $7
            FROM seq_cte
            RETURNING id, parent_id, state_pcode, level_id, pcode, name, color,
                      array_to_string(constituent_pcodes, ',') AS constituent_pcodes,
                      area_sqkm, center_lat, center_lon, created_at, updated_at
        ]], parent_id_cond)
        insert_params = {tenant_id, parent_id_param, state_pcode, level_id,
                         parent_pcode, name, color}
        insert_params.n = 7
    end

    -- Pass explicit param count (stored in .n) so table.unpack works correctly when optional
    -- fields (parent_id, color) are Lua nil — table.unpack stops at nil without explicit n.
    local result, err2 = pg.exec(insert_sql, insert_params, insert_params.n)
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err2}))
        return
    end

    local created = result and result[1]
    if not created then
        ngx.status = 500
        ngx.say('{"error":"Insert failed","code":"INSERT_FAILED"}')
        return
    end

    -- Cascade geom up ancestors if we have constituent_pcodes
    if constituent_pcodes and #constituent_pcodes > 0 then
        local cascade_err = cascade_ancestors(tonumber(created.id))
        if cascade_err then
            -- Non-fatal: log but still return success
            ngx.log(ngx.WARN, "cascade_ancestors error: " .. tostring(cascade_err))
        end
    end

    invalidate_cache()

    ngx.status = 201
    ngx.say(cjson.encode(format_node(created)))
end

local function update_node(nid)
    local body = parse_body()
    if not body then return end

    -- Ownership check
    local chk, err0 = pg.exec(
        "SELECT id FROM geo_hierarchy_nodes WHERE id = $1 AND tenant_id = $2",
        {nid, tenant_id}
    )
    if err0 then ngx.status=502; ngx.say(cjson.encode({error="DB error",code="DB_ERROR",detail=err0})); return end
    if not chk or #chk == 0 then
        ngx.status = 404
        ngx.say('{"error":"Node not found or not owned by this tenant","code":"NOT_FOUND"}')
        return
    end

    local sets   = {"updated_at = NOW()"}
    local params = {}
    local idx    = 1

    if body.name then
        table.insert(sets, "name = $" .. idx); table.insert(params, body.name); idx=idx+1
    end
    if body.color ~= nil then
        table.insert(sets, "color = $" .. idx); table.insert(params, body.color); idx=idx+1
    end

    local recompute_geom = false
    if body.constituent_pcodes ~= nil then
        local pcodes_arr = body.constituent_pcodes
        local pcodes_literal = "{" .. table.concat(pcodes_arr, ",") .. "}"
        table.insert(sets, "constituent_pcodes = $" .. idx .. "::text[]")
        table.insert(params, pcodes_literal)
        idx = idx + 1
        -- Compute geom
        local p = "$" .. (idx-1) .. "::text[]"
        table.insert(sets, "geom = (SELECT ST_MakeValid(ST_Multi(ST_Union(a.geom))) FROM adm_features a WHERE a.pcode = ANY(" .. p .. "))")
        table.insert(sets, "area_sqkm = (SELECT ROUND((ABS(ST_Area(ST_MakeValid(ST_Multi(ST_Union(a.geom)))::geography))/1000000.0)::numeric,2) FROM adm_features a WHERE a.pcode = ANY(" .. p .. "))")
        table.insert(sets, "center_lat = (SELECT ROUND(ST_Y(ST_Centroid(ST_MakeValid(ST_Multi(ST_Union(a.geom)))))::numeric,6) FROM adm_features a WHERE a.pcode = ANY(" .. p .. "))")
        table.insert(sets, "center_lon = (SELECT ROUND(ST_X(ST_Centroid(ST_MakeValid(ST_Multi(ST_Union(a.geom)))))::numeric,6) FROM adm_features a WHERE a.pcode = ANY(" .. p .. "))")
        recompute_geom = true
    end

    table.insert(params, nid)
    local sql = "UPDATE geo_hierarchy_nodes SET " .. table.concat(sets, ", ") ..
                " WHERE id = $" .. idx .. " AND tenant_id = " .. tenant_id ..
                " RETURNING id, parent_id, state_pcode, level_id, pcode, name, color, " ..
                " array_to_string(constituent_pcodes, ',') AS constituent_pcodes, " ..
                " area_sqkm, center_lat, center_lon, created_at, updated_at"

    local result, err2 = pg.exec(sql, params)
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err2}))
        return
    end

    -- Cascade ancestors if geom was recomputed
    if recompute_geom then
        local cascade_err = cascade_ancestors(nid)
        if cascade_err then
            ngx.log(ngx.WARN, "cascade_ancestors error: " .. tostring(cascade_err))
        end
    end

    invalidate_cache()

    local updated = result and result[1]
    ngx.say(cjson.encode(updated and format_node(updated) or {}))
end

local function delete_node(nid)
    -- Get parent_id before deletion for cascade
    local pr, err0 = pg.exec(
        "SELECT parent_id FROM geo_hierarchy_nodes WHERE id = $1 AND tenant_id = $2",
        {nid, tenant_id}
    )
    if err0 then ngx.status=502; ngx.say(cjson.encode({error="DB error",code="DB_ERROR",detail=err0})); return end
    if not pr or #pr == 0 then
        ngx.status = 404
        ngx.say('{"error":"Node not found or not owned by this tenant","code":"NOT_FOUND"}')
        return
    end
    local parent_id = pr[1].parent_id

    local _, err2 = pg.exec(
        "DELETE FROM geo_hierarchy_nodes WHERE id = $1 AND tenant_id = $2",
        {nid, tenant_id}
    )
    if err2 then
        ngx.status = 502
        ngx.say(cjson.encode({error="Database error", code="DB_ERROR", detail=err2}))
        return
    end

    -- Cascade ancestors from parent upward (if parent exists)
    if parent_id and parent_id ~= ngx.null then
        -- Recompute parent directly after deletion
        local _, ce = pg.exec([[
            WITH child_pcodes AS (
                SELECT ARRAY(
                    SELECT DISTINCT UNNEST(constituent_pcodes)
                    FROM geo_hierarchy_nodes
                    WHERE parent_id = $1 AND constituent_pcodes IS NOT NULL
                ) AS pcodes
            ),
            geom_data AS (
                SELECT ST_MakeValid(ST_Multi(ST_Union(a.geom))) AS g
                FROM adm_features a, child_pcodes cp
                WHERE a.pcode = ANY(cp.pcodes)
                  AND cardinality(cp.pcodes) > 0
            )
            UPDATE geo_hierarchy_nodes SET
                constituent_pcodes = (SELECT pcodes FROM child_pcodes),
                geom = (SELECT g FROM geom_data),
                area_sqkm = (SELECT ROUND((ABS(ST_Area(g::geography))/1000000.0)::numeric,2) FROM geom_data),
                center_lat = (SELECT ROUND(ST_Y(ST_Centroid(g))::numeric,6) FROM geom_data),
                center_lon = (SELECT ROUND(ST_X(ST_Centroid(g))::numeric,6) FROM geom_data),
                updated_at = NOW()
            WHERE id = $1
        ]], {parent_id})
        if ce then ngx.log(ngx.WARN, "parent recompute error: " .. tostring(ce)) end

        -- Now cascade further up from parent
        local cascade_err = cascade_ancestors(parent_id)
        if cascade_err then ngx.log(ngx.WARN, "cascade error after delete: " .. tostring(cascade_err)) end
    end

    invalidate_cache()
    ngx.say('{"deleted":true}')
end

-- ===========================================================================
-- Dispatch
-- ===========================================================================

if not resource then
    ngx.status = 404
    ngx.say('{"error":"Not found","code":"INVALID_ENDPOINT"}')
    return
end

if resource == "levels" then
    if method == "GET" and not res_id then
        list_levels()
    elseif method == "POST" and not res_id then
        create_level()
    elseif method == "PUT" and res_id then
        update_level(res_id)
    elseif method == "DELETE" and res_id then
        delete_level(res_id)
    else
        ngx.status = 405
        ngx.say('{"error":"Method not allowed","code":"METHOD_NOT_ALLOWED"}')
    end
elseif resource == "level-labels" then
    if method == "GET" then
        list_level_labels()
    else
        ngx.status = 405
        ngx.say('{"error":"Method not allowed","code":"METHOD_NOT_ALLOWED"}')
    end
elseif resource == "nodes" then
    if method == "GET" and not res_id then
        list_nodes()
    elseif method == "POST" and not res_id then
        create_node()
    elseif method == "PUT" and res_id then
        update_node(res_id)
    elseif method == "DELETE" and res_id then
        delete_node(res_id)
    else
        ngx.status = 405
        ngx.say('{"error":"Method not allowed","code":"METHOD_NOT_ALLOWED"}')
    end
else
    ngx.status = 404
    ngx.say('{"error":"Unknown resource","code":"INVALID_ENDPOINT"}')
end
