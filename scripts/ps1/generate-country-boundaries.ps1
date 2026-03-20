#
# generate-country-boundaries.ps1 - Generate country boundary PMTiles from GeoJSON
#
# Targets include: kenya, uganda, liberia, rwanda, car, india
#
# Input files required in boundaries/:
#   - kenya-boundaries.geojson
#   - uganda-boundaries.geojson
#   - liberia-boundaries.geojson
#   - rwanda-boundaries.geojson
#   - central-african-republic-boundaries.geojson
#
# Usage:
#   .\scripts\generate-country-boundaries.ps1
#   .\scripts\generate-country-boundaries.ps1 -Country kenya
#   .\scripts\generate-country-boundaries.ps1 -Force
#

param(
    [string]$Country = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$BoundariesDir = Join-Path $BaseDir "boundaries"
$TippecanoeImage = "felt-tippecanoe:local"
$Dockerfile = Join-Path $BaseDir "scripts\Dockerfile.tippecanoe"

function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }

$Countries = @(
    @{ Name = "kenya"; File = "kenya-boundaries" }
    @{ Name = "uganda"; File = "uganda-boundaries" }
    @{ Name = "liberia"; File = "liberia-boundaries" }
    @{ Name = "rwanda"; File = "rwanda-boundaries" }
    @{ Name = "car"; File = "central-african-republic-boundaries" }
    @{ Name = "india"; File = "india-boundaries" }
)

if ($Country -ne "") {
    $Countries = $Countries | Where-Object { $_.Name -eq $Country }
    if ($Countries.Count -eq 0) {
        Log-Error "Country '$Country' not found. Available: kenya, uganda, liberia, rwanda, car, india"
        exit 1
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Log-Error "Docker is required to run tippecanoe."
    exit 1
}

$imageExists = docker images -q $TippecanoeImage 2>$null
if (-not $imageExists -or $Force) {
    Log-Info "Building tippecanoe Docker image..."
    docker build -t $TippecanoeImage -f $Dockerfile $BaseDir
    if ($LASTEXITCODE -ne 0) {
        Log-Error "Failed to build $TippecanoeImage"
        exit 1
    }
    Log-Success "Built $TippecanoeImage"
}

$succeeded = @()
$failed = @()
$skipped = @()

foreach ($c in $Countries) {
    $geojsonFile = Join-Path $BoundariesDir "$($c.File).geojson"
    $pmtilesFile = Join-Path $BoundariesDir "$($c.File).pmtiles"

    if (-not (Test-Path $geojsonFile)) {
        Log-Error "Missing GeoJSON: $geojsonFile"
        $failed += "$($c.Name): missing GeoJSON"
        continue
    }

    if ((Test-Path $pmtilesFile) -and -not $Force) {
        Log-Info "$($c.File).pmtiles already exists - skipping (use -Force to regenerate)"
        $skipped += "$($c.Name): exists"
        continue
    }

    Log-Info "Generating $($c.File).pmtiles ..."
    $ContainerName = "tippecanoe-$($c.Name)-$(Get-Random)"

    docker create --name $ContainerName `
        --entrypoint="" `
        -v "${BoundariesDir}:/data:ro" `
        $TippecanoeImage `
        tippecanoe `
            --output="/tmp/$($c.File).pmtiles" `
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
            --name="$($c.File)" `
            --description="Admin boundaries for $($c.Name)" `
            "/data/$($c.File).geojson" | Out-Null

    docker start -a $ContainerName
    $tippecanoeExit = $LASTEXITCODE

    if ($tippecanoeExit -ne 0) {
        Log-Error "tippecanoe failed for $($c.Name)"
        $failed += "$($c.Name): tippecanoe error"
        docker rm $ContainerName 2>$null | Out-Null
        continue
    }

    docker cp "${ContainerName}:/tmp/$($c.File).pmtiles" $pmtilesFile
    docker rm $ContainerName 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Log-Error "Failed to copy output for $($c.Name)"
        $failed += "$($c.Name): docker cp error"
        continue
    }

    Log-Success "$($c.File).pmtiles generated"
    $succeeded += $c.Name
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Country Boundary Generation Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($succeeded.Count -gt 0) { Write-Host "Generated: $($succeeded -join ', ')" -ForegroundColor Green }
if ($skipped.Count -gt 0)   { Write-Host "Skipped:   $($skipped -join ', ')" -ForegroundColor Yellow }
if ($failed.Count -gt 0)    { Write-Host "Failed:    $($failed -join ', ')" -ForegroundColor Red; exit 1 }

Log-Info "Restart Docker after generation:"
Log-Info "  docker compose -f tileserver/docker-compose.tenant.yml restart"
