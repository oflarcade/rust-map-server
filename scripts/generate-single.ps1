#
# generate-single.ps1 - Generate PMTiles for a single country on Windows
# Usage: .\scripts\generate-single.ps1 <country-name>
# Example: .\scripts\generate-single.ps1 nigeria
#

param(
    [switch]$Force,
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Country
)

$ErrorActionPreference = "Stop"

# Configuration
$BaseDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PlanetilerJar = Join-Path $BaseDir "planetiler.jar"
$OsmDataDir = Join-Path $BaseDir "osm-data"
$PmtilesDir = Join-Path $BaseDir "pmtiles"
$DataSourcesDir = Join-Path $BaseDir "data\sources"
$TempDir = Join-Path $BaseDir "temp"

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }

# Memory settings per country
$memoryMap = @{
    "liberia"                  = 2
    "rwanda"                   = 2
    "central-african-republic" = 2
    "uganda"                   = 4
    "kenya"                    = 4
    "nigeria"                  = 6
    "india"                    = 8
}

# Normalize country name
$Country = $Country.ToLower().Trim()

# Validate
if (-not $memoryMap.ContainsKey($Country)) {
    Log-Error "Unknown country: $Country"
    Write-Host ""
    Write-Host "Available countries:" -ForegroundColor Yellow
    foreach ($c in $memoryMap.Keys | Sort-Object) {
        Write-Host "  - $c" -ForegroundColor White
    }
    exit 1
}

$memory = $memoryMap[$Country]
$osmFile = Join-Path $OsmDataDir "$Country-latest.osm.pbf"
$outputFile = Join-Path $PmtilesDir "$Country-detailed.pmtiles"

# Ensure directories exist
New-Item -ItemType Directory -Force -Path $PmtilesDir, $DataSourcesDir, $TempDir | Out-Null

# Skip if output already exists (unless -Force)
if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0) -and (-not $Force)) {
    $existingSize = (Get-Item $outputFile).Length / 1MB
    Log-Info ("{0} already exists ({1:N1} MB) - skipping. Use -Force to regenerate." -f $Country.ToUpper(), $existingSize)
    exit 0
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Generating PMTiles: $($Country.ToUpper())" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Verify Planetiler exists
if (-not (Test-Path $PlanetilerJar)) {
    Log-Error "Planetiler not found at $PlanetilerJar"
    Log-Info "Run .\scripts\setup.ps1 first"
    exit 1
}

# Verify OSM file exists
if (-not (Test-Path $osmFile)) {
    Log-Error "OSM file not found: $osmFile"
    Log-Info "Run .\scripts\setup.ps1 to download OSM data"
    exit 1
}

$inputSize = (Get-Item $osmFile).Length / 1MB
Log-Info ("Input: $osmFile ({0:N1} MB)" -f $inputSize)
Log-Info "Output: $outputFile"
Log-Info "Memory: ${memory}GB"
Log-Info "Note: First run downloads ~1GB of supporting data (coastlines, etc.)"

# Clean up any leftover _inprogress files (Windows rename bug workaround)
Get-ChildItem "$DataSourcesDir\*_inprogress" -ErrorAction SilentlyContinue | Remove-Item -Force

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Run Planetiler with ABSOLUTE paths (fixes Windows file rename issues)
& java "-Xmx${memory}g" -jar $PlanetilerJar `
    --osm-path="$osmFile" `
    --output="$outputFile" `
    --download `
    --download_dir="$DataSourcesDir" `
    --force `
    --maxzoom=14 `
    --minzoom=0 `
    --simplify-tolerance-at-max-zoom=0 `
    --building_merge_z13=true `
    --exclude-layers=poi,housenumber `
    --nodemap-type=sparsearray `
    --storage=ram `
    --nodemap-storage=ram `
    --osm_lazy_reads=false `
    --tmpdir="$TempDir"

$exitCode = $LASTEXITCODE
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed

if ($exitCode -ne 0) {
    Log-Error "Planetiler failed with exit code $exitCode"
    exit 1
}

if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
    $outputSize = (Get-Item $outputFile).Length / 1MB
    Write-Host ""
    Log-Success ("{0} completed in {1:N0}m {2:N0}s" -f $Country.ToUpper(), $elapsed.TotalMinutes, ($elapsed.Seconds))
    Log-Success ("Output: $outputFile ({0:N1} MB)" -f $outputSize)
} else {
    Log-Error "Generation failed - no output file produced or file is empty"
    exit 1
}

# Cleanup temp
if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
