-- Canonical Martin source ids for tenants (PMTiles filename without .pmtiles).
-- generate-states.* now writes nigeria-<slug>-boundaries.pmtiles; legacy uploads used *-admin.
-- Normalize on save so DB + nginx always match Add Tenant + Martin catalog.

local M = {}

--- @param boundary_source string|nil
--- @return string|nil
function M.normalize_boundary_source(boundary_source)
    if not boundary_source or boundary_source == "" then
        return boundary_source
    end
    -- Nigeria state outputs from older generate-states used *-admin.pmtiles; Martin + Add Tenant use *-boundaries
    if boundary_source:match("^nigeria%-") and boundary_source:match("%-admin$") then
        return boundary_source:sub(1, #boundary_source - 6) .. "-boundaries"
    end
    return boundary_source
end

return M
