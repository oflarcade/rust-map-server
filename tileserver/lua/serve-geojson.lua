-- serve-geojson.lua
-- GET /boundaries/geojson
-- Streams a GeoJSON FeatureCollection for the tenant from PostGIS.
-- Includes zones (pre-computed union), states, and ungrouped LGAs.
-- Rwanda and India tenants return an empty FeatureCollection (no HDX data imported).

local cjson = require("cjson.safe")
local db    = require("boundary-db")

local tenant_id = tonumber(ngx.var.http_x_tenant_id)

local rows, err = db.get_geojson(tenant_id)
if err then
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = "Database error", code = "DB_ERROR", detail = err }))
    return
end

ngx.header["Content-Type"]  = "application/geo+json"
ngx.header["Cache-Control"] = "public, max-age=300"
ngx.header["Vary"]          = "X-Tenant-ID"

ngx.print('{"type":"FeatureCollection","features":[')

local first = true
for _, row in ipairs(rows or {}) do
    if row.geometry then
        local props = {
            pcode        = row.pcode,
            name         = row.name,
            feature_type = row.feature_type,
            parent_pcode = row.parent_pcode,
        }
        if row.color and row.color ~= "" then
            props.color = row.color
        end
        if row.constituent_pcodes and row.constituent_pcodes ~= "" then
            props.constituent_pcodes = row.constituent_pcodes
        end

        local feature = '{"type":"Feature","geometry":' .. row.geometry ..
                        ',"properties":' .. cjson.encode(props) .. '}'
        if not first then ngx.print(',') end
        ngx.print(feature)
        first = false
    end
end

ngx.print(']}')
