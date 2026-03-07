#
# generate-nigeria-tenants.ps1 - Regenerate all Nigeria tenant tiles from zoom 6
#
# Generates state-level tiles for all Nigeria tenants with minzoom=6
# so the FE can show the full state on initial load.
#
# Usage: .\scripts\generate-nigeria-tenants.ps1 [-Force]
#
# Tenants:
#   3  - Bridge Nigeria (Lagos + Osun combined)
#   9  - EdoBEST (Edo)
#   11 - EKOEXCEL (Lagos)
#   14 - Kwara Learn (Kwara)
#   16 - Bayelsa Prime (Bayelsa)
#   18 - Jigawa Unite (Jigawa)
#

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ── Configuration ───────────────────────────────────────────
$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$PlanetilerJar = Join-Path $BaseDir "planetiler.jar"
$OsmFile = Join-Path $BaseDir "osm-data\nigeria-latest.osm.pbf"
$OutputDir = Join-Path $BaseDir "pmtiles\z6"
$DataSourcesDir = Join-Path $BaseDir "data\sources"
$TempDir = Join-Path $BaseDir "temp"
$HdxAdm1 = Join-Path $BaseDir "data\hdx\nigeria_adm1.geojson"
$StatesBoundsDir = Join-Path $BaseDir "data\sources\nigeria-states"
$BoundsScript = Join-Path $BaseDir "scripts\bounds-from-hdx.py"

$MinZoom = 6
$MaxZoom = 14
$Memory = 6
$Layers = "water,landuse,landcover,building,transportation,place"

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Warn    { param($msg) Write-Host "[WARN] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Yellow }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }
function Log-Step    { param($msg) Write-Host "[STEP] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Cyan }

# Nigeria tenant state definitions
# Each entry: OutputName (Martin source name), States to include, Bounds (computed from HDX adm1)
$Tenants = @(
    @{ Id = 9;  OutputName = "nigeria-edo";        States = @("Edo") }
    @{ Id = 11; OutputName = "nigeria-lagos";       States = @("Lagos") }
    @{ Id = 14; OutputName = "nigeria-kwara";       States = @("Kwara") }
    @{ Id = 16; OutputName = "nigeria-bayelsa";     States = @("Bayelsa") }
    @{ Id = 18; OutputName = "nigeria-jigawa";      States = @("Jigawa") }
    @{ Id = 3;  OutputName = "nigeria-lagos-osun";  States = @("Lagos", "Osun") }
)

# ── Prerequisites ───────────────────────────────────────────
if (-not (Test-Path $PlanetilerJar)) {
    Log-Error "Planetiler not found: $PlanetilerJar"
    Log-Info "Run .\scripts\setup.ps1 first"
    exit 1
}

if (-not (Test-Path $OsmFile)) {
    Log-Error "OSM file not found: $OsmFile"
    Log-Info "Run .\scripts\setup.ps1 to download Nigeria OSM data"
    exit 1
}

if (-not (Test-Path $HdxAdm1)) {
    Log-Error "HDX file not found: $HdxAdm1"
    Log-Info "Run .\scripts\download-hdx.ps1 to fetch Nigeria HDX COD-AB data"
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutputDir, $DataSourcesDir, $TempDir, $StatesBoundsDir | Out-Null

# Clean up any leftover _inprogress files
Get-ChildItem "$DataSourcesDir\*_inprogress" -ErrorAction SilentlyContinue | Remove-Item -Force

$inputSize = (Get-Item $OsmFile).Length / 1MB

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Nigeria Tenant Tile Generator" -ForegroundColor Cyan
Write-Host "  Zoom:    $MinZoom-$MaxZoom (full state visible from z$MinZoom)" -ForegroundColor Cyan
Write-Host "  Layers:  $Layers" -ForegroundColor Cyan
Write-Host "  Memory:  ${Memory}GB" -ForegroundColor Cyan
Write-Host "  Input:   $OsmFile ($([math]::Round($inputSize)) MB)" -ForegroundColor Cyan
Write-Host "  Output:  $OutputDir\" -ForegroundColor Cyan
Write-Host "  Tenants: $($Tenants.Count)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Compute bounding boxes from HDX adm1 ─────────────
Log-Step "Step 1: Computing bounding boxes from HDX adm1..."

# Collect all unique states
$allStates = @()
foreach ($t in $Tenants) {
    foreach ($s in $t.States) {
        if ($allStates -notcontains $s) { $allStates += $s }
    }
}

Log-Info "States needed: $($allStates -join ', ')"

& python $BoundsScript $HdxAdm1 $StatesBoundsDir @allStates
if ($LASTEXITCODE -ne 0) {
    Log-Error "Failed to compute bounds from HDX data"
    exit 1
}

$BoundsFile = Join-Path $StatesBoundsDir "bounds.json"
if (-not (Test-Path $BoundsFile)) {
    Log-Error "Bounds file not generated"
    exit 1
}

$boundsData = Get-Content $BoundsFile | ConvertFrom-Json
Log-Success "Bounding boxes computed for $($allStates.Count) states"

# ── Step 2: Generate tiles per tenant ───────────────────────
Log-Step "Step 2: Generating tiles for $($Tenants.Count) Nigeria tenants (zoom $MinZoom-$MaxZoom)..."

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$succeeded = @()
$skipped = @()
$failed = @()
$tenantIndex = 0

foreach ($tenant in $Tenants) {
    $tenantIndex++
    $outputFile = Join-Path $OutputDir "$($tenant.OutputName).pmtiles"

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Log-Info "[$tenantIndex/$($Tenants.Count)] Tenant $($tenant.Id): $($tenant.OutputName)"
    Log-Info "  States: $($tenant.States -join ' + ')"

    # Skip if exists (unless -Force)
    if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0) -and -not $Force) {
        $existingSize = (Get-Item $outputFile).Length / 1MB
        Log-Warn ("{0} already exists ({1:N1} MB) - skipping. Use -Force to regenerate." -f $tenant.OutputName, $existingSize)
        $skipped += $tenant.OutputName
        continue
    }

    # Compute combined bounds for multi-state tenants
    if ($tenant.States.Count -eq 1) {
        $slug = $tenant.States[0].ToLower().Replace(' ', '-')
        $bounds = $boundsData.$slug.bounds
    } else {
        # Merge bounds across multiple states
        $minLon = [double]::MaxValue
        $minLat = [double]::MaxValue
        $maxLon = [double]::MinValue
        $maxLat = [double]::MinValue

        foreach ($state in $tenant.States) {
            $slug = $state.ToLower().Replace(' ', '-')
            $sb = $boundsData.$slug
            if ($sb.min_lon -lt $minLon) { $minLon = $sb.min_lon }
            if ($sb.min_lat -lt $minLat) { $minLat = $sb.min_lat }
            if ($sb.max_lon -gt $maxLon) { $maxLon = $sb.max_lon }
            if ($sb.max_lat -gt $maxLat) { $maxLat = $sb.max_lat }
        }
        $bounds = "{0:F6},{1:F6},{2:F6},{3:F6}" -f $minLon, $minLat, $maxLon, $maxLat
    }

    Log-Info "  Bounds: $bounds"
    Log-Info "  Output: $outputFile"

    $stateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    & java "-Xmx${Memory}g" -jar $PlanetilerJar `
        --osm-path="$OsmFile" `
        --output="$outputFile" `
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
        Log-Error "Planetiler failed for $($tenant.OutputName) (exit code $exitCode)"
        $failed += $tenant.OutputName
        continue
    }

    if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
        $outSize = (Get-Item $outputFile).Length / 1MB
        Log-Success ("{0} generated in {1:N0}s ({2:N1} MB)" -f $tenant.OutputName, $stateStopwatch.Elapsed.TotalSeconds, $outSize)
        $succeeded += $tenant.OutputName
    } else {
        Log-Error "No output for $($tenant.OutputName)"
        $failed += $tenant.OutputName
    }
}

# ── Summary ─────────────────────────────────────────────────
$totalStopwatch.Stop()
$totalElapsed = $totalStopwatch.Elapsed

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Nigeria Tenant Tile Generation Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("  Total time: {0:N0}m {1:N0}s" -f [math]::Floor($totalElapsed.TotalMinutes), $totalElapsed.Seconds) -ForegroundColor White
Write-Host "  Zoom range: $MinZoom-$MaxZoom" -ForegroundColor White
Write-Host ""

if ($succeeded.Count -gt 0) {
    Log-Success "Generated ($($succeeded.Count)):"
    foreach ($s in $succeeded) {
        $f = Join-Path $OutputDir "$s.pmtiles"
        $sz = (Get-Item $f).Length / 1MB
        Write-Host ("  + {0} ({1:N1} MB)" -f $s, $sz) -ForegroundColor Green
    }
}

if ($skipped.Count -gt 0) {
    Write-Host ""
    Log-Warn "Skipped ($($skipped.Count)) - use -Force to regenerate:"
    foreach ($s in $skipped) {
        $f = Join-Path $OutputDir "$s.pmtiles"
        $sz = (Get-Item $f).Length / 1MB
        Write-Host ("  ~ {0} ({1:N1} MB)" -f $s, $sz) -ForegroundColor Yellow
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Log-Error "Failed ($($failed.Count)):"
    foreach ($f in $failed) {
        Write-Host "  x $f" -ForegroundColor Red
    }
}

Write-Host ""
Log-Info "Next steps:"
Log-Info "  1. Restart Docker: docker compose -f tileserver/docker-compose.tenant.yml restart"
Log-Info "  2. Verify catalog: curl.exe http://localhost:3000/catalog"
Log-Info "  3. Test in browser: http://localhost:8000/test/test-tenant-tiles.html"

# Cleanup temp
if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
