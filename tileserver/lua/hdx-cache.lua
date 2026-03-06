-- hdx-cache.lua
-- Worker-level cache for parsed HDX GeoJSON. Key: prefix..":"..level.
-- Paths: /data/hdx/<prefix>_adm1.geojson, /data/hdx/<prefix>_adm2.geojson

local cjson = require("cjson.safe")
local _cache = {}

local function get_adm(prefix, level)
    local key = prefix .. ":" .. level
    if _cache[key] ~= nil then
        return _cache[key]
    end
    local path = "/data/hdx/" .. prefix .. "_" .. level .. ".geojson"
    local f = io.open(path, "r")
    if not f then
        _cache[key] = false
        return false
    end
    local content = f:read("*a")
    f:close()
    local data = cjson.decode(content)
    _cache[key] = data
    return data
end

return { get_adm = get_adm }
