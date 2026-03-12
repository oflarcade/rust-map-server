local ALLOWED = {
    ["http://localhost:3000"] = true,
    ["http://localhost:5173"] = true,
    ["http://localhost:4000"] = true,
    ["http://localhost:8000"] = true,
    ["http://localhost:8080"] = true,
    ["http://35.239.86.115"] = true,
}

if ngx.req.get_method() == "OPTIONS" then
    ngx.header["Access-Control-Allow-Origin"]  = ngx.req.get_headers()["Origin"] or "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "X-Tenant-ID, X-Admin-Token, Content-Type"
    ngx.header["Access-Control-Max-Age"]       = "86400"
    ngx.status = 204
    return ngx.exit(204)
end

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
