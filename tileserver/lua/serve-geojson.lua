-- serve-geojson.lua
-- Serves boundary GeoJSON for a tenant: merges /data/hdx/<prefix>_adm1.geojson + _adm2.geojson

local prefix = ngx.var.hdx_prefix
if not prefix or prefix == "" then
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"No HDX boundary data for this tenant","code":"HDX_NOT_AVAILABLE"}')
    return
end

local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function features_inner(content)
    local open_marker = content:find('"features"%s*:%s*%[')
    if not open_marker then return nil end
    local open = content:find('%[', open_marker) + 1
    local close = content:find('%]%s*}[%s%c]*$')
    if not close then return nil end
    return content:sub(open, close - 1)
end

local adm1 = read_all("/data/hdx/" .. prefix .. "_adm1.geojson")
local adm2 = read_all("/data/hdx/" .. prefix .. "_adm2.geojson")

if not adm1 or not adm2 then
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"HDX GeoJSON not found","code":"GEOJSON_NOT_FOUND","prefix":"' .. prefix .. '"}')
    return
end

local inner1 = features_inner(adm1)
local inner2 = features_inner(adm2)

if not inner1 or not inner2 then
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Failed to parse HDX GeoJSON","code":"PARSE_ERROR","prefix":"' .. prefix .. '"}')
    return
end

ngx.header["Content-Type"]  = "application/geo+json"
ngx.header["Cache-Control"] = "public, max-age=3600"

local sep = (inner1 ~= "" and inner2 ~= "") and ',' or ''
ngx.print('{"type":"FeatureCollection","features":[')
ngx.print(inner1)
ngx.print(sep)
ngx.print(inner2)
ngx.print(']}')
