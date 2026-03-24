-- Single access_by_lua handler: CORS preflight + validate tenant + origin whitelist.
-- OPTIONS must run before tenant checks (preflight may not send X-Tenant-ID).

local ALLOWED = {
    ["http://localhost:3000"] = true,
    ["http://localhost:5173"] = true,
    ["http://localhost:4000"] = true,
    ["http://localhost:8000"] = true,
    ["http://localhost:8080"] = true,
    ["http://35.239.86.115"] = true,
    ["http://35.224.96.155"] = true,
}

if ngx.req.get_method() == "OPTIONS" then
    ngx.header["Access-Control-Allow-Origin"]  = ngx.req.get_headers()["Origin"] or "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "X-Tenant-ID, X-Admin-Token, Content-Type"
    ngx.header["Access-Control-Max-Age"]       = "86400"
    ngx.status = 204
    return ngx.exit(204)
end

-- --- validate-tenant (same as validate-tenant.lua) ---
local tid = ngx.var.http_x_tenant_id
if not tid or tid == "" then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"X-Tenant-ID header is required","code":"MISSING_TENANT_ID"}\n')
    ngx.exit(400)
end

local ts = ngx.var.tenant_source
if not ts or ts == "" then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Invalid tenant ID","code":"INVALID_TENANT_ID","tenant_id":"' .. tid .. '"}\n')
    ngx.exit(400)
end

local uri = ngx.var.uri
if uri == "/boundaries.json" or uri:match("^/boundaries/%d+/%d+/%d+$") then
    local bs = ngx.var.boundary_source
    if not bs or bs == "" then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"No boundary data for this tenant","code":"NO_BOUNDARY_DATA","tenant_id":"' .. tid .. '"}\n')
        ngx.exit(404)
    end
end

-- --- origin-whitelist (non-OPTIONS; same as origin-whitelist.lua tail) ---
local function origin_from_referer(ref)
    return ref and ref:match("^(https?://[^/]+)")
end

local function deny(key, val)
    ngx.status = 403
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Access denied","code":"ORIGIN_BLOCKED","' .. key .. '":"' .. (val or "") .. '"}')
    return ngx.exit(403)
end

local headers = ngx.req.get_headers()
local origin  = headers["Origin"]
local referer = headers["Referer"]

if origin and origin ~= "" then
    if not ALLOWED[origin] then return deny("origin", origin) end
    ngx.header["Access-Control-Allow-Origin"]  = origin
    ngx.header["Access-Control-Allow-Headers"] = "X-Tenant-ID, Content-Type"
    ngx.header["Vary"] = "Origin"
elseif referer and referer ~= "" then
    local ref_origin = origin_from_referer(referer)
    if ref_origin and not ALLOWED[ref_origin] then return deny("referer", referer) end
end
