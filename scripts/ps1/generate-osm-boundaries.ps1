#
# generate-osm-boundaries.ps1 - Extract admin boundary GeoJSON from OSM .pbf files
#
# Uses Docker (osgeo/gdal) to run ogr2ogr against each country's .osm.pbf,
# extracting administrative boundaries (admin_level 4/5/6) as GeoJSON.
#
# Output files are placed in boundaries/ and are the input for
# generate-country-boundaries.ps1 (tippecanoe -> PMTiles step).
#
# License: OSM data is ODbL (open source / commercial-friendly)
#
# Usage:
#   .\scripts\generate-osm-boundaries.ps1                    # All countries
#   .\scripts\generate-osm-boundaries.ps1 -Country kenya     # Single country
#   .\scripts\generate-osm-boundaries.ps1 -Force             # Regenerate existing
#
# Countries: kenya, uganda, liberia, rwanda, car
#

param(
    [string]$Country = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$BaseDir     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$OsmDataDir  = Join-Path $BaseDir "osm-data"
$BoundariesDir = Join-Path $BaseDir "boundaries"
$GdalImage   = "ghcr.io/osgeo/gdal:ubuntu-small-latest"

function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }

# Country definitions: Name | OsmFile (in osm-data/) | Output base name (in boundaries/)
$Countries = @(
    @{ Name = "kenya";                    OsmFile = "kenya-latest.osm.pbf";                    File = "kenya-boundaries" }
    @{ Name = "uganda";                   OsmFile = "uganda-latest.osm.pbf";                   File = "uganda-boundaries" }
    @{ Name = "liberia";                  OsmFile = "liberia-latest.osm.pbf";                  File = "liberia-boundaries" }
    @{ Name = "rwanda";                   OsmFile = "rwanda-latest.osm.pbf";                   File = "rwanda-boundaries" }
    @{ Name = "car";                      OsmFile = "central-african-republic-latest.osm.pbf"; File = "central-african-republic-boundaries" }
)

# Filter to single country if specified
if ($Country -ne "") {
    $Countries = $Countries | Where-Object { $_.Name -eq $Country }
    if ($Countries.Count -eq 0) {
        Log-Error "Country '$Country' not found. Available: kenya, uganda, liberia, rwanda, car"
        exit 1
    }
}

# Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Log-Error "Docker is required. Install Docker Desktop and try again."
    exit 1
}

New-Item -ItemType Directory -Force -Path $BoundariesDir | Out-Null

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  OSM Boundary GeoJSON Extractor" -ForegroundColor Cyan
Write-Host "  Countries: $($Countries.Count)" -ForegroundColor Cyan
Write-Host "  Image: $GdalImage" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$succeeded = @()
$failed    = @()
$skipped   = @()

foreach ($c in $Countries) {
    $osmFile     = Join-Path $OsmDataDir $c.OsmFile
    $geojsonFile = Join-Path $BoundariesDir "$($c.File).geojson"

    Write-Host "────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Log-Info "$($c.Name) -> $($c.File).geojson"

    # Check OSM source exists
    if (-not (Test-Path $osmFile)) {
        Log-Error "OSM file missing: $osmFile"
        $failed += "$($c.Name): missing $($c.OsmFile)"
        continue
    }

    # Skip if already exists
    if ((Test-Path $geojsonFile) -and -not $Force) {
        $sz = (Get-Item $geojsonFile).Length / 1MB
        Log-Info ("{0} already exists ({1:N1} MB) - skipping (use -Force to regenerate)" -f $c.File, $sz)
        $skipped += "$($c.Name): exists"
        continue
    }

    $ContainerName = "ogr2ogr-$($c.Name)-$(Get-Random)"

    Log-Info "Running ogr2ogr in Docker (this may take several minutes for large files)..."

    # Use docker create + start + cp to avoid Windows bind mount write permission issues.
    # Input (osm-data/) is mounted read-only; output goes to /tmp inside the container.
    docker create --name $ContainerName `
        --entrypoint="" `
        -v "${OsmDataDir}:/input:ro" `
        $GdalImage `
        ogr2ogr `
            -f GeoJSON `
            "/tmp/$($c.File).geojson" `
            "/input/$($c.OsmFile)" `
            multipolygons `
            -where "boundary='administrative' AND (admin_level='4' OR admin_level='5' OR admin_level='6')" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Log-Error "docker create failed for $($c.Name)"
        $failed += "$($c.Name): docker create error"
        continue
    }

    docker start -a $ContainerName
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Log-Error "ogr2ogr failed for $($c.Name) (exit $exitCode)"
        $failed += "$($c.Name): ogr2ogr error (exit $exitCode)"
        docker rm $ContainerName 2>$null | Out-Null
        continue
    }

    docker cp "${ContainerName}:/tmp/$($c.File).geojson" $geojsonFile
    $cpExit = $LASTEXITCODE
    docker rm $ContainerName 2>$null | Out-Null

    if ($cpExit -ne 0) {
        Log-Error "docker cp failed for $($c.Name)"
        $failed += "$($c.Name): docker cp error"
        continue
    }

    if ((Test-Path $geojsonFile) -and ((Get-Item $geojsonFile).Length -gt 0)) {
        $sz = (Get-Item $geojsonFile).Length / 1MB
        Log-Success ("{0}.geojson written ({1:N1} MB)" -f $c.File, $sz)
        $succeeded += $c.Name
    } else {
        Log-Error "Output file missing or empty for $($c.Name)"
        $failed += "$($c.Name): empty output"
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Extraction Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($succeeded.Count -gt 0) { Write-Host "Generated: $($succeeded -join ', ')" -ForegroundColor Green }
if ($skipped.Count -gt 0)   { Write-Host "Skipped:   $($skipped -join ', ')"   -ForegroundColor Yellow }
if ($failed.Count -gt 0)    { Write-Host "Failed:    $($failed -join ', ')"     -ForegroundColor Red; exit 1 }

Write-Host ""
Log-Info "Next step: convert GeoJSONs to PMTiles:"
Log-Info "  .\scripts\generate-country-boundaries.ps1"
