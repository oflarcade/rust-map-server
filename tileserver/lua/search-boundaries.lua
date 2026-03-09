-- search-boundaries.lua
-- GET /boundaries/search?q=<query>
-- Case-insensitive partial match on admin boundary names from PostGIS.
-- Searches adm1 (states) + adm2 (LGAs) + zones within tenant scope.
-- Tenant identified by X-Tenant-ID header.
--
-- Response: { query, count, results: [{ pcode, name, adm_level, parent_pcode }] }

local cjson = require("cjson.safe")
local db    = require("boundary-db")

local q = ngx.var.arg_q or ""
if q == "" then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Missing required parameter: ?q=","code":"MISSING_QUERY"}')
    return
end

local tenant_id = tonumber(ngx.var.http_x_tenant_id)

local rows, err = db.search(tenant_id, q)
if err then
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err }))
    return
end

local results = {}
for _, row in ipairs(rows or {}) do
    table.insert(results, {
        pcode        = row.pcode,
        name         = row.name,
        adm_level    = tonumber(row.adm_level),
        parent_pcode = row.parent_pcode,
    })
end

ngx.header["Content-Type"]  = "application/json"
ngx.header["Cache-Control"] = "no-store"
ngx.say(cjson.encode({
    query   = q,
    count   = #results,
    results = results,
}))
