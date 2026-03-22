-- pg-pool.lua
-- OpenResty pgmoon connection pool.
-- Uses cosocket keepalive for per-worker connection reuse.
-- All queries use native pgmoon parameterized syntax ($1, $2, ...).

local pgmoon = require("pgmoon")

local M = {}

local CONFIG = {
    host     = os.getenv("PGHOST")     or "postgres",
    port     = tonumber(os.getenv("PGPORT") or "5432"),
    database = os.getenv("PGDATABASE") or "mapserver",
    user     = os.getenv("PGUSER")     or "mapserver",
    -- no password needed: postgres uses trust auth on Docker internal network
}

-- Execute a SQL query with optional positional parameters ($1, $2, ...).
-- Pass nparams explicitly when the params array contains nil values (e.g. optional SQL NULL
-- fields), because table.unpack stops at the first nil when no explicit end index is given.
-- Returns result table on success, nil + error string on failure.
function M.exec(sql, params, nparams)
    local pg = pgmoon.new(CONFIG)
    local ok, err = pg:connect()
    if not ok then
        return nil, "pg connect failed: " .. (err or "unknown")
    end

    local result, err2
    if params then
        local n = nparams or params.n or #params
        result, err2 = pg:query(sql, table.unpack(params, 1, n))
    else
        result, err2 = pg:query(sql)
    end

    -- Return connection to the cosocket pool (30s keepalive, max 100 per worker)
    pg:keepalive(30000, 100)

    if not result then
        return nil, "pg query failed: " .. (err2 or "unknown")
    end
    return result
end

return M
