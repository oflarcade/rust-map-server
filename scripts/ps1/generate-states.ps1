#
# generate-states.ps1 - Generate PMTiles for states within a country on Windows
#
# Usage: .\scripts\generate-states.ps1 <profile> <country> [state1] [state2] ...
#        .\scripts\generate-states.ps1 -List <profile> <country>
#
# If no states are specified, auto-discovers ALL states from HDX adm1 and generates
# tiles for each one. Use -List to see available states without generating.
#
# Profiles:
#   full     - water + roads + places (largest, most detail)
#   minimal  - water + places only (smallest, bare minimum)
#   terrain  - water + landuse + landcover + buildings + places (balanced)
#
# Examples:
#   .\scripts\generate-states.ps1 terrain nigeria                       # All states
#   .\scripts\generate-states.ps1 terrain nigeria Lagos Edo Bayelsa     # Specific states
#   .\scripts\generate-states.ps1 -List terrain nigeria                 # List states only
#

param(
    [switch]$List,
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Profile,
    [Parameter(Mandatory=$true, Position=1)]
    [string]$Country,
    [Parameter(Position=2, ValueFromRemainingArguments=$true)]
    [string[]]$States
)

$ErrorActionPreference = "Stop"

# Configuration
$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$PlanetilerJar = Join-Path $BaseDir "planetiler.jar"
$OsmDataDir = Join-Path $BaseDir "osm-data"
$TempDir = Join-Path $BaseDir "temp"
$DataSourcesDir = Join-Path $BaseDir "data\sources"
$BoundsScript = Join-Path $BaseDir "scripts\bounds-from-hdx.py"

$MinZoom = 10
$MaxZoom = 14

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Warn    { param($msg) Write-Host "[WARN] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Yellow }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }
function Log-Step    { param($msg) Write-Host "[STEP] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Cyan }

# Profile definitions
$ProfileLayers = @{
    "full"          = "water,landuse,landcover,building,transportation,place"
    "terrain-roads" = "water,landuse,landcover,transportation,place"
    "terrain"       = "water,landuse,landcover,place"
    "minimal"       = "water,place"
}

$ProfileDesc = @{
    "full"          = "Water + roads + landuse + buildings + places (largest)"
    "terrain-roads" = "Water + landuse + roads + places (no buildings)"
    "terrain"       = "Water + landuse + landcover + places (no buildings, no roads)"
    "minimal"       = "Water + places only (smallest)"
}

# Memory allocation per country (GB)
$MemoryMap = @{
    "liberia"                  = 2
    "rwanda"                   = 2
    "central-african-republic" = 2
    "uganda"                   = 4
    "kenya"                    = 4
    "nigeria"                  = 6
    "india"                    = 8
}

# Normalize
$Country = $Country.ToLower().Trim()
$Profile = $Profile.ToLower().Trim()

# Validate profile
if (-not $ProfileLayers.ContainsKey($Profile)) {
    Log-Error "Unknown profile: $Profile"
    Write-Host ""
    Write-Host "Available profiles:" -ForegroundColor Yellow
    foreach ($p in $ProfileLayers.Keys | Sort-Object) {
        Write-Host "  $p - $($ProfileDesc[$p])" -ForegroundColor White
    }
    exit 1
}

# Validate country
if (-not $MemoryMap.ContainsKey($Country)) {
    Log-Error "Unknown country: $Country"
    Write-Host ""
    Write-Host "Available countries:" -ForegroundColor Yellow
    foreach ($c in $MemoryMap.Keys | Sort-Object) {
        Write-Host "  - $c" -ForegroundColor White
    }
    exit 1
}

$Layers = $ProfileLayers[$Profile]
$Memory = $MemoryMap[$Country]
$HdxAdm1 = Join-Path $BaseDir "data\hdx\${Country}_adm1.geojson"
$StatesBoundsDir = Join-Path $BaseDir "data\sources\${Country}-states"

# Profile-specific output directories
$OutputDir = Join-Path $BaseDir "pmtiles\$Profile"
$BoundariesDir = Join-Path $BaseDir "boundaries\$Profile"

# Verify HDX adm1 file
if (-not (Test-Path $HdxAdm1)) {
    Log-Error "HDX file not found: $HdxAdm1"
    Log-Info "Run .\scripts\download-hdx.ps1 to fetch HDX COD-AB data for $Country"
    exit 1
}

# --List mode: show available states and exit (from HDX adm1_name)
if ($List) {
    Write-Host ""
    Log-Info "Available states for ${Country} (from HDX adm1):"
    Write-Host ""
    & python -c @"
import json
with open(r'$HdxAdm1') as f:
    data = json.load(f)
states = sorted(set(f['properties'].get('adm1_name') for f in data['features'] if f['properties'].get('adm1_name')))
for s in states:
    print(f'  - {s}')
print(f'\nTotal: {len(states)} states')
"@
    exit 0
}

# Auto-discover: if no states provided, get ALL states from HDX adm1
if (-not $States -or $States.Count -eq 0) {
    Log-Info "No states specified - auto-discovering all states from HDX adm1..."
    $stateOutput = & python -c @"
import json
with open(r'$HdxAdm1') as f:
    data = json.load(f)
states = sorted(set(f['properties'].get('adm1_name') for f in data['features'] if f['properties'].get('adm1_name')))
for s in states:
    print(s)
"@
    $States = $stateOutput | Where-Object { $_.Trim() -ne "" }
    Log-Info "Found $($States.Count) states for $Country"
}

# Verify prerequisites
if (-not (Test-Path $PlanetilerJar)) {
    Log-Error "Planetiler not found at $PlanetilerJar"
    Log-Info "Run .\scripts\setup.ps1 first"
    exit 1
}

$OsmFile = Join-Path $OsmDataDir "${Country}-latest.osm.pbf"
if (-not (Test-Path $OsmFile)) {
    Log-Error "OSM file not found: $OsmFile"
    Log-Info "Run .\scripts\setup.ps1 to download OSM data"
    exit 1
}

# Create directories
New-Item -ItemType Directory -Force -Path $OutputDir, $BoundariesDir, $TempDir, $DataSourcesDir, $StatesBoundsDir | Out-Null

# Clean up any leftover _inprogress files
Get-ChildItem "$DataSourcesDir\*_inprogress" -ErrorAction SilentlyContinue | Remove-Item -Force

$InputSize = (Get-Item $OsmFile).Length / 1MB

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  State-Level PMTiles Generator" -ForegroundColor Cyan
Write-Host "  Profile: $Profile" -ForegroundColor Cyan
Write-Host "  Layers:  $Layers" -ForegroundColor Cyan
Write-Host "  Country: $Country" -ForegroundColor Cyan
Write-Host "  States:  $($States -join ', ')" -ForegroundColor Cyan
Write-Host "  Zoom:    $MinZoom-$MaxZoom" -ForegroundColor Cyan
Write-Host "  Output:  pmtiles/$Profile/" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ─────────────────────────────────────────────────────────────
# Step 1: Compute bounds from HDX adm1
# ─────────────────────────────────────────────────────────────
Write-Host ""
Log-Step "Step 1: Computing bounds from HDX adm1 for selected states..."

& python $BoundsScript $HdxAdm1 $StatesBoundsDir @States
if ($LASTEXITCODE -ne 0) {
    Log-Error "Failed to compute bounds from HDX data. Check state names."
    exit 1
}

$BoundsFile = Join-Path $StatesBoundsDir "bounds.json"
if (-not (Test-Path $BoundsFile)) {
    Log-Error "Bounds file not generated"
    exit 1
}

Log-Success "Bounds computed from HDX adm1"

# Read state slugs from bounds.json
$boundsData = Get-Content $BoundsFile | ConvertFrom-Json
$StateSlugs = $boundsData.PSObject.Properties.Name

# ─────────────────────────────────────────────────────────────
# Step 2: Generate per-state OSM base map tiles
# ─────────────────────────────────────────────────────────────
Write-Host ""
Log-Step "Step 2: Generating [$Profile] OSM tiles per state (zoom $MinZoom-$MaxZoom)..."

$succeeded = @()
$failed = @()
$stateIndex = 0

foreach ($slug in $StateSlugs) {
    $stateIndex++
    $bounds = $boundsData.$slug.bounds
    $stateName = $boundsData.$slug.name
    $stateOutput = Join-Path $OutputDir "${Country}-${slug}.pmtiles"

    Write-Host ""
    Log-Info "[$stateIndex/$($StateSlugs.Count)] Generating [$Profile] tiles for ${stateName}..."
    Log-Info "  Layers: $Layers"
    Log-Info "  Bounds: $bounds"
    Log-Info "  Output: $stateOutput"
    Log-Info "  Memory: ${Memory}GB | Zoom: $MinZoom-$MaxZoom"

    $stateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    & java "-Xmx${Memory}g" -jar $PlanetilerJar `
        --osm-path="$OsmFile" `
        --output="$stateOutput" `
        --download `
        --download_dir="$DataSourcesDir" `
        --force `
        --bounds="$bounds" `
        --maxzoom=$MaxZoom `
        --minzoom=$MinZoom `
        --simplify-tolerance-at-max-zoom=0.1 `
        --only-layers=$Layers `
        --nodemap-type=sparsearray `
        --storage=ram `
        --nodemap-storage=ram `
        --osm_lazy_reads=false `
        --tmpdir="$TempDir"

    $exitCode = $LASTEXITCODE
    $stateStopwatch.Stop()

    if ($exitCode -ne 0) {
        Log-Error "Planetiler failed for ${stateName} with exit code $exitCode"
        $failed += $stateName
        continue
    }

    if ((Test-Path $stateOutput) -and ((Get-Item $stateOutput).Length -gt 0)) {
        $stateSize = (Get-Item $stateOutput).Length / 1MB
        Log-Success ("{0} [{1}] tiles generated in {2:N0}s ({3:N1} MB)" -f $stateName, $Profile, $stateStopwatch.Elapsed.TotalSeconds, $stateSize)
        $succeeded += $stateName
    } else {
        Log-Error "Failed to generate tiles for ${stateName}"
        $failed += $stateName
    }
}

# ─────────────────────────────────────────────────────────────
# Step 3: Boundary tiles (tippecanoe) — skip on Windows with warning
# ─────────────────────────────────────────────────────────────
Write-Host ""
$hasTippecanoe = $null -ne (Get-Command tippecanoe -ErrorAction SilentlyContinue)

if ($hasTippecanoe) {
    Log-Step "Step 3: Generating admin boundary tiles..."

    foreach ($slug in $StateSlugs) {
        $stateName = $boundsData.$slug.name
        $stateGeojson = Join-Path $StatesBoundsDir "${slug}.json"
        $boundaryOutput = Join-Path $BoundariesDir "${Country}-${slug}-boundaries.pmtiles"

        if (-not (Test-Path $stateGeojson)) {
            Log-Warn "No state GeoJSON for $stateName, skipping boundaries"
            continue
        }

        Log-Info "Generating boundaries for ${stateName}..."

        & tippecanoe `
            --output="$boundaryOutput" `
            --force `
            --maximum-zoom=$MaxZoom `
            --minimum-zoom=$MinZoom `
            --no-feature-limit `
            --no-tile-size-limit `
            --detect-shared-borders `
            --no-simplification-of-shared-nodes `
            --coalesce-densest-as-needed `
            --extend-zooms-if-still-dropping `
            --layer=admin `
            --name="${Country}-${slug}-boundaries" `
            --description="Admin boundaries for ${stateName}, ${Country}" `
            $stateGeojson

        if ((Test-Path $boundaryOutput) -and ((Get-Item $boundaryOutput).Length -gt 0)) {
            $bSize = (Get-Item $boundaryOutput).Length / 1MB
            Log-Success ("{0} boundaries: {1:N1} MB" -f $stateName, $bSize)
        }
    }

    # Combined boundary tiles
    $combinedGeojson = Join-Path $StatesBoundsDir "combined.json"
    $combinedBoundary = Join-Path $BoundariesDir "${Country}-states-boundaries.pmtiles"

    if (Test-Path $combinedGeojson) {
        Log-Info "Generating combined boundary tiles..."

        & tippecanoe `
            --output="$combinedBoundary" `
            --force `
            --maximum-zoom=$MaxZoom `
            --minimum-zoom=$MinZoom `
            --no-feature-limit `
            --no-tile-size-limit `
            --detect-shared-borders `
            --no-simplification-of-shared-nodes `
            --coalesce-densest-as-needed `
            --extend-zooms-if-still-dropping `
            --layer=admin `
            --name="${Country}-states-boundaries" `
            --description="Admin boundaries for selected states in ${Country}" `
            $combinedGeojson

        if ((Test-Path $combinedBoundary) -and ((Get-Item $combinedBoundary).Length -gt 0)) {
            $cSize = (Get-Item $combinedBoundary).Length / 1MB
            Log-Success ("Combined boundaries: {0:N1} MB" -f $cSize)
        }
    }
} else {
    Log-Warn "tippecanoe not found - skipping boundary tile generation"
    Log-Info "Boundary tiles require tippecanoe (not typically available on Windows)"
    Log-Info "Generate boundaries on macOS/Linux with: ./scripts/sh/generate-boundaries.sh"
}

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
$totalStopwatch.Stop()
$totalElapsed = $totalStopwatch.Elapsed

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  [$Profile] State Tile Generation Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Profile: $Profile ($($ProfileDesc[$Profile]))" -ForegroundColor White
Write-Host ("  Total time: {0:N0}m {1:N0}s" -f [math]::Floor($totalElapsed.TotalMinutes), $totalElapsed.Seconds) -ForegroundColor White
Write-Host ""

if ($succeeded.Count -gt 0) {
    Log-Info "Succeeded ($($succeeded.Count)):"
    foreach ($s in $succeeded) {
        Write-Host "  + $s" -ForegroundColor Green
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Log-Error "Failed ($($failed.Count)):"
    foreach ($f in $failed) {
        Write-Host "  - $f" -ForegroundColor Red
    }
}

Write-Host ""
Log-Info "Generated [$Profile] OSM base map tiles:"
foreach ($slug in $StateSlugs) {
    $file = Join-Path $OutputDir "${Country}-${slug}.pmtiles"
    if (Test-Path $file) {
        $size = (Get-Item $file).Length / 1MB
        Write-Host ("  + {0} ({1:N1} MB)" -f (Split-Path -Leaf $file), $size) -ForegroundColor Green
    }
}

if ($hasTippecanoe) {
    Write-Host ""
    Log-Info "Generated [$Profile] boundary tiles:"
    foreach ($slug in $StateSlugs) {
        $file = Join-Path $BoundariesDir "${Country}-${slug}-boundaries.pmtiles"
        if (Test-Path $file) {
            $size = (Get-Item $file).Length / 1MB
            Write-Host ("  + {0} ({1:N1} MB)" -f (Split-Path -Leaf $file), $size) -ForegroundColor Green
        }
    }
}

# Cleanup temp
if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
