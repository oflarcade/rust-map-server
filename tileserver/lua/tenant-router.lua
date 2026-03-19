-- tenant-router.lua
-- Returns {tile_source, boundary_source} for a tenant_id from DB.
-- Cached in ngx.shared.tenant_cache (1MB, 300s TTL).
-- Used as a fallback for tenants not covered by the static nginx map blocks.

local cjson = require("cjson.safe")
local pg    = require("pg-pool")

local M = {}

local cache = ngx.shared.tenant_cache

function M.get(tenant_id)
    if not tenant_id then return nil end
    local key = tostring(tenant_id)

    -- Check shared cache first
    if cache then
        local hit = cache:get(key)
        if hit then return cjson.decode(hit) end
    end

    -- DB lookup
    local rows, err = pg.exec(
        "SELECT tile_source, boundary_source FROM tenants WHERE tenant_id = $1",
        {tenant_id}
    )
    if err or not rows or #rows == 0 then return nil end

    local cfg = {
        tile_source     = rows[1].tile_source     or "",
        boundary_source = rows[1].boundary_source or "",
    }

    if cache then cache:set(key, cjson.encode(cfg), 300) end
    return cfg
end

-- Invalidate cached entry for a tenant (call after tenant update)
function M.invalidate(tenant_id)
    if cache and tenant_id then
        cache:delete(tostring(tenant_id))
    end
end

return M
