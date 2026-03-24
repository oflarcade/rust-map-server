-- access_by_lua: must run after rewrite_by_lua (resolve-tenant.lua).
-- nginx `if ($tenant_source = "")` can run before rewrite_by_lua in the same location,
-- so validation belongs in the access phase.

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
