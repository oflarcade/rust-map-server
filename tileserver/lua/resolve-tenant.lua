-- Included first in each location that uses $tenant_source / $boundary_source.
-- See tenant-router.lua for STATIC + Postgres resolution.

local ok, router = pcall(require, "tenant-router")
if not ok or not router then
    ngx.log(ngx.ERR, "resolve-tenant: require tenant-router failed: ", tostring(router))
    return
end

local tid_str = ngx.var.http_x_tenant_id
if not tid_str or tid_str == "" then
    return
end

local cfg = router.get(tonumber(tid_str))
if cfg and cfg.tile_source and cfg.tile_source ~= "" then
    ngx.var.tenant_source   = cfg.tile_source
    ngx.var.boundary_source = cfg.boundary_source or ""
end
