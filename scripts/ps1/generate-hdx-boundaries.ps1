#
# generate-hdx-boundaries.ps1 - Generate HDX COD-AB boundary PMTiles for comparison
#
# Converts HDX COD-AB ADM1 + ADM2 GeoJSON files into PMTiles using tippecanoe (Docker).
# Output filenames use the -hdx suffix so they coexist with OSM and GADM boundary tiles
# and can be toggled in the tile inspector.
#
# Targets:
#   - nigeria-boundaries-hdx
#   - kenya-boundaries-hdx
#   - uganda-boundaries-hdx
#   - rwanda-boundaries-hdx
#   - liberia-boundaries-hdx
#   - central-african-republic-boundaries-hdx
#
# Input files required in hdx/:
#   - nigeria_adm1.geojson + nigeria_adm2.geojson
#   - kenya_adm1.geojson + kenya_adm2.geojson
#   - etc.
#
# Usage:
#   .\scripts\generate-hdx-boundaries.ps1
#   .\scripts\generate-hdx-boundaries.ps1 -Country kenya
#   .\scripts\generate-hdx-boundaries.ps1 -Country nigeria -Force
#   .\scripts\generate-hdx-boundaries.ps1 -Force
#

param(
    [string]$Country = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$BaseDir         = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$HdxDir          = Join-Path $BaseDir "hdx"
$BoundariesDir   = Join-Path $BaseDir "boundaries"
$TippecanoeImage = "felt-tippecanoe:local"
$Dockerfile      = Join-Path $BaseDir "scripts\Dockerfile.tippecanoe"

function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }

# HdxPrefix  = base name used in hdx/ filenames (e.g. "kenya" -> hdx/kenya_adm1.geojson)
# OutFile    = output PMTiles stem (without .pmtiles extension)
# ShortName  = short identifier for -Country filter and log labels
$Countries = @(
    @{ Name = "Kenya";                    HdxPrefix = "kenya";                    OutFile = "kenya-boundaries-hdx";                    ShortName = "kenya"   }
    @{ Name = "Uganda";                   HdxPrefix = "uganda";                   OutFile = "uganda-boundaries-hdx";                   ShortName = "uganda"  }
    @{ Name = "Liberia";                  HdxPrefix = "liberia";                  OutFile = "liberia-boundaries-hdx";                  ShortName = "liberia" }
    @{ Name = "Central African Republic"; HdxPrefix = "central-african-republic"; OutFile = "central-african-republic-boundaries-hdx"; ShortName = "car"     }
    @{ Name = "Nigeria";                  HdxPrefix = "nigeria";                  OutFile = "nigeria-boundaries-hdx";                  ShortName = "nigeria" }
)
# Rwanda excluded: HDX package has no GeoJSON (only SHP/EMF). Use GADM for Rwanda instead.

if ($Country -ne "") {
    $Countries = $Countries | Where-Object { $_.ShortName -eq $Country -or $_.HdxPrefix -eq $Country }
    if ($Countries.Count -eq 0) {
        Log-Error "Country '$Country' not found. Available: kenya, uganda, liberia, car, nigeria"
        Log-Error "(Rwanda excluded -- no GeoJSON in HDX package)"
        exit 1
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Log-Error "Docker is required to run tippecanoe."
    exit 1
}

$imageExists = docker images -q $TippecanoeImage 2>$null
if (-not $imageExists) {
    Log-Info "Building tippecanoe Docker image..."
    docker build -t $TippecanoeImage -f $Dockerfile $BaseDir
    if ($LASTEXITCODE -ne 0) {
        Log-Error "Failed to build $TippecanoeImage"
        exit 1
    }
    Log-Success "Built $TippecanoeImage"
}

New-Item -ItemType Directory -Force -Path $BoundariesDir | Out-Null

$succeeded = @()
$failed    = @()
$skipped   = @()

foreach ($c in $Countries) {
    $adm1File    = Join-Path $HdxDir "$($c.HdxPrefix)_adm1.geojson"
    $adm2File    = Join-Path $HdxDir "$($c.HdxPrefix)_adm2.geojson"
    $pmtilesFile = Join-Path $BoundariesDir "$($c.OutFile).pmtiles"

    # Validate input files exist
    $missing = @()
    if (-not (Test-Path $adm1File)) { $missing += "$($c.HdxPrefix)_adm1.geojson" }
    if (-not (Test-Path $adm2File)) { $missing += "$($c.HdxPrefix)_adm2.geojson" }
    if ($missing.Count -gt 0) {
        Log-Error "Missing HDX files for $($c.Name): $($missing -join ', ')"
        Log-Error "  Run: .\scripts\download-hdx.ps1"
        $failed += "$($c.ShortName): missing HDX source files"
        continue
    }

    if ((Test-Path $pmtilesFile) -and -not $Force) {
        Log-Info "$($c.OutFile).pmtiles already exists - skipping (use -Force to regenerate)"
        $skipped += "$($c.ShortName): exists"
        continue
    }

    Log-Info "Generating $($c.OutFile).pmtiles from HDX data..."
    $ContainerName = "tippecanoe-hdx-$($c.ShortName)-$(Get-Random)"

    # Mount the hdx/ directory read-only; tippecanoe writes to /tmp inside the container
    docker create --name $ContainerName `
        --entrypoint="" `
        -v "${HdxDir}:/hdx:ro" `
        $TippecanoeImage `
        tippecanoe `
            --output="/tmp/$($c.OutFile).pmtiles" `
            --force `
            --maximum-zoom=14 `
            --minimum-zoom=0 `
            --no-feature-limit `
            --no-tile-size-limit `
            --detect-shared-borders `
            --no-simplification-of-shared-nodes `
            --coalesce-densest-as-needed `
            --extend-zooms-if-still-dropping `
            --layer=boundaries `
            --name="$($c.OutFile)" `
            --description="HDX COD-AB admin boundaries for $($c.Name) (CC BY-IGO)" `
            "/hdx/$($c.HdxPrefix)_adm1.geojson" `
            "/hdx/$($c.HdxPrefix)_adm2.geojson" | Out-Null

    docker start -a $ContainerName
    $tippecanoeExit = $LASTEXITCODE

    if ($tippecanoeExit -ne 0) {
        Log-Error "tippecanoe failed for $($c.Name)"
        $failed += "$($c.ShortName): tippecanoe error"
        docker rm $ContainerName 2>$null | Out-Null
        continue
    }

    docker cp "${ContainerName}:/tmp/$($c.OutFile).pmtiles" $pmtilesFile
    $cpExit = $LASTEXITCODE
    docker rm $ContainerName 2>$null | Out-Null

    if ($cpExit -ne 0) {
        Log-Error "Failed to copy output for $($c.Name)"
        $failed += "$($c.ShortName): docker cp error"
        continue
    }

    Log-Success "$($c.OutFile).pmtiles generated"
    $succeeded += $c.ShortName
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  HDX Boundary Generation Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($succeeded.Count -gt 0) { Write-Host "Generated: $($succeeded -join ', ')" -ForegroundColor Green }
if ($skipped.Count -gt 0)   { Write-Host "Skipped:   $($skipped -join ', ')" -ForegroundColor Yellow }
if ($failed.Count -gt 0)    { Write-Host "Failed:    $($failed -join ', ')" -ForegroundColor Red; exit 1 }

Log-Info "Restart Docker to make tiles discoverable by Martin:"
Log-Info "  docker compose -f tileserver/docker-compose.tenant.yml restart"
Log-Info "Verify with:"
Log-Info "  curl.exe http://localhost:3000/catalog"
