#
# generate-gadm-boundaries.ps1 - Generate GADM-based boundary PMTiles for comparison
#
# Converts GADM 4.1 _1.json (admin level 1) + _2.json (admin level 2) files
# into PMTiles using tippecanoe (Docker). Output filenames use the -gadm suffix
# so they coexist with OSM-derived boundary tiles and can be toggled in the tile
# inspector.
#
# Targets:
#   - kenya-boundaries-gadm
#   - uganda-boundaries-gadm
#   - liberia-boundaries-gadm
#   - rwanda-boundaries-gadm
#   - central-african-republic-boundaries-gadm
#   - nigeria-boundaries-gadm
#
# Input files required in gadm/:
#   - kenya_1.json + kenya_2.json
#   - uganda_1.json + uganda_2.json
#   - liberia_1.json + liberia_2.json
#   - rwanda_1.json + rwanda_2.json
#   - central-african-republic_1.json + central-african-republic_2.json
#   - nigeria_1.json + nigeria_2.json
#
# Usage:
#   .\scripts\generate-gadm-boundaries.ps1
#   .\scripts\generate-gadm-boundaries.ps1 -Country kenya
#   .\scripts\generate-gadm-boundaries.ps1 -Country nigeria -Force
#   .\scripts\generate-gadm-boundaries.ps1 -Force
#

param(
    [string]$Country = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$BaseDir      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$GadmDir      = Join-Path $BaseDir "gadm"
$BoundariesDir = Join-Path $BaseDir "boundaries"
$TippecanoeImage = "felt-tippecanoe:local"
$Dockerfile   = Join-Path $BaseDir "scripts\Dockerfile.tippecanoe"

function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }

# GadmPrefix = base name used in gadm/ filenames (e.g. "kenya" -> gadm/kenya_1.json)
# OutFile    = output PMTiles stem (without .pmtiles extension)
# Name       = human-readable country name for logs and --description
$Countries = @(
    @{ Name = "Kenya";                    GadmPrefix = "kenya";                    OutFile = "kenya-boundaries-gadm";                    ShortName = "kenya"   }
    @{ Name = "Uganda";                   GadmPrefix = "uganda";                   OutFile = "uganda-boundaries-gadm";                   ShortName = "uganda"  }
    @{ Name = "Liberia";                  GadmPrefix = "liberia";                  OutFile = "liberia-boundaries-gadm";                  ShortName = "liberia" }
    @{ Name = "Rwanda";                   GadmPrefix = "rwanda";                   OutFile = "rwanda-boundaries-gadm";                   ShortName = "rwanda"  }
    @{ Name = "Central African Republic"; GadmPrefix = "central-african-republic"; OutFile = "central-african-republic-boundaries-gadm"; ShortName = "car"     }
    @{ Name = "Nigeria";                  GadmPrefix = "nigeria";                  OutFile = "nigeria-boundaries-gadm";                  ShortName = "nigeria" }
)

if ($Country -ne "") {
    $Countries = $Countries | Where-Object { $_.ShortName -eq $Country -or $_.GadmPrefix -eq $Country }
    if ($Countries.Count -eq 0) {
        Log-Error "Country '$Country' not found. Available: kenya, uganda, liberia, rwanda, car, nigeria"
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
    $gadm1File  = Join-Path $GadmDir "$($c.GadmPrefix)_1.json"
    $gadm2File  = Join-Path $GadmDir "$($c.GadmPrefix)_2.json"
    $pmtilesFile = Join-Path $BoundariesDir "$($c.OutFile).pmtiles"

    # Validate input files exist
    $missing = @()
    if (-not (Test-Path $gadm1File)) { $missing += "$($c.GadmPrefix)_1.json" }
    if (-not (Test-Path $gadm2File)) { $missing += "$($c.GadmPrefix)_2.json" }
    if ($missing.Count -gt 0) {
        Log-Error "Missing GADM files for $($c.Name): $($missing -join ', ')"
        Log-Error "  Run: .\scripts\download-gadm.ps1"
        $failed += "$($c.ShortName): missing GADM source files"
        continue
    }

    if ((Test-Path $pmtilesFile) -and -not $Force) {
        Log-Info "$($c.OutFile).pmtiles already exists - skipping (use -Force to regenerate)"
        $skipped += "$($c.ShortName): exists"
        continue
    }

    Log-Info "Generating $($c.OutFile).pmtiles from GADM data..."
    $ContainerName = "tippecanoe-gadm-$($c.ShortName)-$(Get-Random)"

    # Mount the gadm/ directory read-only; tippecanoe writes to /tmp inside the container
    docker create --name $ContainerName `
        --entrypoint="" `
        -v "${GadmDir}:/gadm:ro" `
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
            --description="GADM 4.1 admin boundaries for $($c.Name)" `
            "/gadm/$($c.GadmPrefix)_1.json" `
            "/gadm/$($c.GadmPrefix)_2.json" | Out-Null

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
Write-Host "  GADM Boundary Generation Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($succeeded.Count -gt 0) { Write-Host "Generated: $($succeeded -join ', ')" -ForegroundColor Green }
if ($skipped.Count -gt 0)   { Write-Host "Skipped:   $($skipped -join ', ')" -ForegroundColor Yellow }
if ($failed.Count -gt 0)    { Write-Host "Failed:    $($failed -join ', ')" -ForegroundColor Red; exit 1 }

Log-Info "Restart Docker to make tiles discoverable by Martin:"
Log-Info "  docker compose -f tileserver/docker-compose.tenant.yml restart"
Log-Info "Verify with:"
Log-Info "  curl.exe http://localhost:3000/catalog"
