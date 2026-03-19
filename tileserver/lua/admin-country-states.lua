-- admin-country-states.lua
-- GET /admin/states?country_code=XX
-- Returns all adm_level=1 states for a country with their adm_level=2 LGA children.
-- Used by the Add Tenant wizard (no X-Tenant-ID required).

local pg = require("pg-pool")
local cjson = require("cjson")

local function send_json(status, obj)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(obj))
    ngx.exit(status)
end

if ngx.req.get_method() ~= "GET" then
    send_json(405, { error = "Method Not Allowed" })
    return
end

local args = ngx.req.get_uri_args()
local country_code = args.country_code
if not country_code or country_code == "" then
    send_json(400, { error = "country_code query parameter required" })
    return
end
country_code = country_code:upper()

-- Fetch all states for this country
local state_res, state_err = pg.exec(
    "SELECT pcode, name FROM adm_features WHERE adm_level = 1 AND country_code = $1 ORDER BY name",
    { country_code }
)
if not state_res then
    ngx.log(ngx.ERR, "states query error: ", state_err)
    send_json(500, { error = "Query failed" })
    return
end

-- Fetch all LGAs for this country in one query
local lga_res, lga_err = pg.exec(
    "SELECT pcode, name, parent_pcode FROM adm_features WHERE adm_level = 2 AND country_code = $1 ORDER BY name",
    { country_code }
)
if not lga_res then
    ngx.log(ngx.ERR, "lga query error: ", lga_err)
    send_json(500, { error = "Query failed" })
    return
end

-- Group LGAs by parent_pcode
local lgas_by_state = {}
for _, lga in ipairs(lga_res) do
    local parent = lga.parent_pcode or ""
    if parent ~= "" then
        if not lgas_by_state[parent] then lgas_by_state[parent] = {} end
        table.insert(lgas_by_state[parent], { pcode = lga.pcode, name = lga.name })
    end
end

-- Build response
local states = {}
for _, state in ipairs(state_res) do
    table.insert(states, {
        pcode    = state.pcode,
        name     = state.name,
        children = lgas_by_state[state.pcode] or {},
    })
end

ngx.header["Content-Type"] = "application/json"
ngx.header["Cache-Control"] = "public, max-age=3600"
ngx.say(cjson.encode({ country_code = country_code, states = states }))
