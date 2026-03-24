-- tenant-router.lua
-- Returns {tile_source, boundary_source} for a tenant_id.
-- 1) Built-in static IDs (same routing the old nginx map used — fast, no DB).
-- 2) ngx.shared.tenant_cache (300s TTL).
-- 3) Postgres tenants table.

local cjson = require("cjson.safe")
local pg    = require("pg-pool")

local M = {}

local cache = ngx.shared.tenant_cache

-- Keep in sync with historical nginx map (add new built-in tenants here if needed).
local STATIC = {
    [1]  = { tile_source = "kenya-detailed",                    boundary_source = "kenya-boundaries" },
    [2]  = { tile_source = "uganda-detailed",                   boundary_source = "uganda-boundaries" },
    [3]  = { tile_source = "nigeria-lagos-osun",                boundary_source = "nigeria-lagos-osun-boundaries" },
    [4]  = { tile_source = "liberia-detailed",                  boundary_source = "liberia-boundaries" },
    [5]  = { tile_source = "india-andhrapradesh",               boundary_source = "india-boundaries" },
    [9]  = { tile_source = "nigeria-edo",                       boundary_source = "nigeria-edo-boundaries" },
    [11] = { tile_source = "nigeria-lagos",                     boundary_source = "nigeria-lagos-boundaries" },
    [12] = { tile_source = "rwanda-detailed",                   boundary_source = "rwanda-boundaries" },
    [14] = { tile_source = "nigeria-kwara",                     boundary_source = "nigeria-kwara-boundaries" },
    [15] = { tile_source = "india-manipur",                     boundary_source = "india-boundaries" },
    [16] = { tile_source = "nigeria-bayelsa",                   boundary_source = "nigeria-bayelsa-boundaries" },
    [17] = { tile_source = "central-african-republic-detailed", boundary_source = "central-african-republic-boundaries" },
    [18] = { tile_source = "nigeria-jigawa",                    boundary_source = "nigeria-jigawa-boundaries" },
}

function M.get(tenant_id)
    if not tenant_id then return nil end
    local key = tostring(tenant_id)

    local built_in = STATIC[tenant_id]
    if built_in then return built_in end

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
