#
# generate-tenants.ps1 - Generate tiles for all configured tenants
#
# Usage: .\scripts\generate-tenants.ps1              # All tenants
#        .\scripts\generate-tenants.ps1 -Tenant 11   # Single tenant
#        .\scripts\generate-tenants.ps1 -Profile terrain # Override profile (default: full)
#

param(
    [int]$Tenant = 0,
    [string]$Profile = "full"
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$PlanetilerJar = Join-Path $BaseDir "planetiler.jar"
$OsmDataDir = Join-Path $BaseDir "osm-data"
$DataSourcesDir = Join-Path $BaseDir "data\sources"
$TempDir = Join-Path $BaseDir "temp"
$StatesBase = Join-Path $BaseDir "data\sources"

# Profile layers
$ProfileLayers = @{
    "full"          = "water,landuse,landcover,building,transportation,place"
    "terrain-roads" = "water,landuse,landcover,transportation,place"
    "terrain"       = "water,landuse,landcover,place"
    "minimal"       = "water,place"
}

# Memory per country
$MemoryMap = @{
    "liberia" = 2; "rwanda" = 2; "central-african-republic" = 2
    "uganda" = 4; "kenya" = 4; "nigeria" = 6; "india" = 8
}

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }
function Log-Warn    { param($msg) Write-Host "[WARN] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Yellow }
function Log-Step    { param($msg) Write-Host "[STEP] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Cyan }

# ══════════════════════════════════════════════════════════════
# TENANT CONFIGURATION
# ══════════════════════════════════════════════════════════════
# States = @()         → full country tile
# States = @("Lagos")  → single state tile
# States = @("Lagos","Osun") + Combined = $true → combined multi-state tile
# ══════════════════════════════════════════════════════════════

$Tenants = @(
    @{ Id = 1;  Name = "Bridge Kenya";        Country = "kenya";                    States = @();                        Combined = $false }
    @{ Id = 2;  Name = "Bridge Uganda";        Country = "uganda";                   States = @();                        Combined = $false }
    @{ Id = 3;  Name = "Bridge Nigeria";       Country = "nigeria";                  States = @("Lagos","Osun");          Combined = $true  }
    @{ Id = 4;  Name = "Bridge Liberia";       Country = "liberia";                  States = @();                        Combined = $false }
    @{ Id = 5;  Name = "Bridge India";         Country = "india";                    States = @("AndhraPradesh");         Combined = $false }
    @{ Id = 9;  Name = "EdoBEST";              Country = "nigeria";                  States = @("Edo");                   Combined = $false }
    @{ Id = 11; Name = "EKOEXCEL";             Country = "nigeria";                  States = @("Lagos");                 Combined = $false }
    @{ Id = 12; Name = "Rwanda EQUIP";         Country = "rwanda";                   States = @();                        Combined = $false }
    @{ Id = 14; Name = "Kwara Learn";          Country = "nigeria";                  States = @("Kwara");                 Combined = $false }
    @{ Id = 15; Name = "Manipur Education";    Country = "india";                    States = @("Manipur");               Combined = $false }
    @{ Id = 16; Name = "Bayelsa Prime";        Country = "nigeria";                  States = @("Bayelsa");               Combined = $false }
    @{ Id = 17; Name = "Espoir CAR";           Country = "central-african-republic"; States = @();                        Combined = $false }
    @{ Id = 18; Name = "Jigawa Unite";         Country = "nigeria";                  States = @("Jigawa");                Combined = $false }
)

# Validate profile
if (-not $ProfileLayers.ContainsKey($Profile)) {
    Log-Error "Unknown profile: $Profile. Available: $($ProfileLayers.Keys -join ', ')"
    exit 1
}

$Layers = $ProfileLayers[$Profile]

# Filter to single tenant if specified
if ($Tenant -gt 0) {
    $Tenants = $Tenants | Where-Object { $_.Id -eq $Tenant }
    if ($Tenants.Count -eq 0) {
        Log-Error "Tenant $Tenant not found"
        exit 1
    }
}

# Safety checks
if (-not (Test-Path $PlanetilerJar)) {
    Log-Error "Planetiler not found: $PlanetilerJar"
    exit 1
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Tenant Tile Generator" -ForegroundColor Cyan
Write-Host "  Profile: $Profile" -ForegroundColor Cyan
Write-Host "  Tenants: $($Tenants.Count)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Show what will be generated
foreach ($t in $Tenants) {
    if ($t.States.Count -eq 0) {
        Write-Host "  Tenant $($t.Id) ($($t.Name)): $($t.Country) full country" -ForegroundColor White
    } elseif ($t.Combined) {
        Write-Host "  Tenant $($t.Id) ($($t.Name)): $($t.Country) [$($t.States -join ' + ')] combined" -ForegroundColor White
    } else {
        Write-Host "  Tenant $($t.Id) ($($t.Name)): $($t.Country) [$($t.States -join ', ')]" -ForegroundColor White
    }
}
Write-Host ""

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$succeeded = @()
$failed = @()
$skipped = @()

# Track which full-country tiles we've already generated to avoid duplicates
$generatedCountries = @{}
# Track which individual states we've already generated to avoid duplicates
$generatedStates = @{}

$tenantIndex = 0
foreach ($t in $Tenants) {
    $tenantIndex++
    $country = $t.Country
    $memory = $MemoryMap[$country]
    $osmFile = Join-Path $OsmDataDir "${country}-latest.osm.pbf"

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Log-Step "[$tenantIndex/$($Tenants.Count)] Tenant $($t.Id): $($t.Name)"
    Write-Host "────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    # Check OSM file exists
    if (-not (Test-Path $osmFile)) {
        Log-Error "OSM file missing: $osmFile - skipping tenant $($t.Id)"
        $failed += "Tenant $($t.Id) ($($t.Name)): missing $osmFile"
        continue
    }

    # ── FULL COUNTRY ──────────────────────────────────────────
    if ($t.States.Count -eq 0) {
        $outputFile = Join-Path $BaseDir "pmtiles\${country}-detailed.pmtiles"
        $outputDir = Join-Path $BaseDir "pmtiles"
        New-Item -ItemType Directory -Force -Path $outputDir, $DataSourcesDir, $TempDir | Out-Null

        # Skip if already generated this country
        if ($generatedCountries.ContainsKey($country)) {
            Log-Info "$country already generated this run - skipping"
            $skipped += "Tenant $($t.Id) ($($t.Name)): $country (already done)"
            continue
        }

        # Skip if file already exists
        if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
            $sz = (Get-Item $outputFile).Length / 1MB
            Log-Info ("{0} already exists ({1:N1} MB) - skipping" -f $country, $sz)
            $skipped += "Tenant $($t.Id) ($($t.Name)): $country (exists)"
            $generatedCountries[$country] = $true
            continue
        }

        Log-Info "Generating full country: $country (${memory}GB RAM)"

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

        if ($LASTEXITCODE -ne 0) {
            Log-Error "Failed for tenant $($t.Id) ($country)"
            $failed += "Tenant $($t.Id) ($($t.Name)): Planetiler exit code $LASTEXITCODE"
            continue
        }

        if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
            $sz = (Get-Item $outputFile).Length / 1MB
            Log-Success ("{0} generated ({1:N1} MB)" -f $country, $sz)
            $succeeded += "Tenant $($t.Id) ($($t.Name)): $country full"
            $generatedCountries[$country] = $true
        } else {
            Log-Error "No output for $country"
            $failed += "Tenant $($t.Id) ($($t.Name)): empty output"
        }
    }
    # ── COMBINED MULTI-STATE ──────────────────────────────────
    elseif ($t.Combined) {
        $slugs = ($t.States | ForEach-Object { $_.ToLower().Replace(' ', '-') }) -join '-'
        $outputFile = Join-Path $BaseDir "pmtiles\${country}-${slugs}.pmtiles"
        $outputDir = Split-Path $outputFile
        New-Item -ItemType Directory -Force -Path $outputDir, $DataSourcesDir, $TempDir | Out-Null

        $stateKey = "${country}-${slugs}"
        if ($generatedStates.ContainsKey($stateKey)) {
            Log-Info "$stateKey already generated this run - skipping"
            $skipped += "Tenant $($t.Id) ($($t.Name)): $stateKey (already done)"
            continue
        }

        if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
            $sz = (Get-Item $outputFile).Length / 1MB
            Log-Info ("{0} already exists ({1:N1} MB) - skipping" -f $stateKey, $sz)
            $skipped += "Tenant $($t.Id) ($($t.Name)): $stateKey (exists)"
            $generatedStates[$stateKey] = $true
            continue
        }

        # Need polygon file for exact state clipping
        $geojsonFile = Join-Path $StatesBase "${country}-states\${slugs}.json"
        if (-not (Test-Path $geojsonFile)) {
            Log-Error "GeoJSON file missing: $geojsonFile — for India run: node scripts/extract-india-state-clips.js (after india-boundaries.geojson); for HDX countries use bounds-from-hdx.py"
            $failed += "Tenant $($t.Id) ($($t.Name)): missing GeoJSON file"
            continue
        }

        # Convert GeoJSON to .poly format (Planetiler requires OSM poly format)
        $polyFile = Join-Path $TempDir "${slugs}.poly"
        New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
        & python -c @"
import json
with open(r'$geojsonFile') as f:
    data = json.load(f)
with open(r'$polyFile', 'w') as out:
    out.write('polygon\n')
    idx = 1
    for feat in data['features']:
        geom = feat['geometry']
        polys = geom['coordinates'] if geom['type'] == 'MultiPolygon' else [geom['coordinates']]
        for poly in polys:
            for i, ring in enumerate(poly):
                prefix = '!' if i > 0 else ''
                out.write(f'{prefix}{idx}\n')
                for lon, lat in ring:
                    out.write(f'   {lon:.6E}   {lat:.6E}\n')
                out.write('END\n')
                idx += 1
    out.write('END\n')
"@
        if ($LASTEXITCODE -ne 0) {
            Log-Error "Failed to convert GeoJSON to .poly for $slugs"
            $failed += "Tenant $($t.Id) ($($t.Name)): .poly conversion failed"
            continue
        }

        Log-Info "Generating combined [$($t.States -join ' + ')] polygon: $polyFile"

        & java "-Xmx${memory}g" -jar $PlanetilerJar `
            --osm-path="$osmFile" `
            --output="$outputFile" `
            --download `
            --download_dir="$DataSourcesDir" `
            --force `
            --polygon="$polyFile" `
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

        if ($LASTEXITCODE -ne 0) {
            Log-Error "Failed for tenant $($t.Id)"
            $failed += "Tenant $($t.Id) ($($t.Name)): Planetiler exit code $LASTEXITCODE"
            continue
        }

        if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
            $sz = (Get-Item $outputFile).Length / 1MB
            Log-Success ("{0} generated ({1:N1} MB)" -f $stateKey, $sz)
            $succeeded += "Tenant $($t.Id) ($($t.Name)): $stateKey combined"
            $generatedStates[$stateKey] = $true
        } else {
            Log-Error "No output for $stateKey"
            $failed += "Tenant $($t.Id) ($($t.Name)): empty output"
        }
    }
    # ── SINGLE STATE ──────────────────────────────────────────
    else {
        foreach ($state in $t.States) {
            $slug = $state.ToLower().Replace(' ', '-')
            $outputFile = Join-Path $BaseDir "pmtiles\${country}-${slug}.pmtiles"
            $outputDir = Split-Path $outputFile
            New-Item -ItemType Directory -Force -Path $outputDir, $DataSourcesDir, $TempDir | Out-Null

            $stateKey = "${country}-${slug}"
            if ($generatedStates.ContainsKey($stateKey)) {
                Log-Info "$stateKey already generated this run - skipping"
                $skipped += "Tenant $($t.Id) ($($t.Name)): $stateKey (already done)"
                continue
            }

            if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
                $sz = (Get-Item $outputFile).Length / 1MB
                Log-Info ("{0} already exists ({1:N1} MB) - skipping" -f $stateKey, $sz)
                $skipped += "Tenant $($t.Id) ($($t.Name)): $stateKey (exists)"
                $generatedStates[$stateKey] = $true
                continue
            }

            # Need polygon file for exact state clipping
            $geojsonFile = Join-Path $StatesBase "${country}-states\${slug}.json"
            if (-not (Test-Path $geojsonFile)) {
                Log-Error "GeoJSON file missing: $geojsonFile — for India run: node scripts/extract-india-state-clips.js (after india-boundaries.geojson); for HDX countries use bounds-from-hdx.py"
                $failed += "Tenant $($t.Id) ($($t.Name)): missing GeoJSON file"
                continue
            }

            # Convert GeoJSON to .poly format (Planetiler requires OSM poly format)
            $polyFile = Join-Path $TempDir "${slug}.poly"
            New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
            & python -c @"
import json
with open(r'$geojsonFile') as f:
    data = json.load(f)
with open(r'$polyFile', 'w') as out:
    out.write('polygon\n')
    idx = 1
    for feat in data['features']:
        geom = feat['geometry']
        polys = geom['coordinates'] if geom['type'] == 'MultiPolygon' else [geom['coordinates']]
        for poly in polys:
            for i, ring in enumerate(poly):
                prefix = '!' if i > 0 else ''
                out.write(f'{prefix}{idx}\n')
                for lon, lat in ring:
                    out.write(f'   {lon:.6E}   {lat:.6E}\n')
                out.write('END\n')
                idx += 1
    out.write('END\n')
"@
            if ($LASTEXITCODE -ne 0) {
                Log-Error "Failed to convert GeoJSON to .poly for $slug"
                $failed += "Tenant $($t.Id) ($($t.Name)): .poly conversion failed"
                continue
            }

            Log-Info "Generating $state polygon: $polyFile"

            & java "-Xmx${memory}g" -jar $PlanetilerJar `
                --osm-path="$osmFile" `
                --output="$outputFile" `
                --download `
                --download_dir="$DataSourcesDir" `
                --force `
                --polygon="$polyFile" `
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

            if ($LASTEXITCODE -ne 0) {
                Log-Error "Failed for $state"
                $failed += "Tenant $($t.Id) ($($t.Name)): Planetiler exit code $LASTEXITCODE"
                continue
            }

            if ((Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
                $sz = (Get-Item $outputFile).Length / 1MB
                Log-Success ("{0} generated ({1:N1} MB)" -f $stateKey, $sz)
                $succeeded += "Tenant $($t.Id) ($($t.Name)): $stateKey"
                $generatedStates[$stateKey] = $true
            } else {
                Log-Error "No output for $stateKey"
                $failed += "Tenant $($t.Id) ($($t.Name)): empty output"
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
$totalStopwatch.Stop()
$totalElapsed = $totalStopwatch.Elapsed

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Tenant Tile Generation Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("  Total time: {0:N0}h {1:N0}m {2:N0}s" -f [math]::Floor($totalElapsed.TotalHours), $totalElapsed.Minutes, $totalElapsed.Seconds) -ForegroundColor White

if ($succeeded.Count -gt 0) {
    Write-Host ""
    Write-Host "  Generated ($($succeeded.Count)):" -ForegroundColor Green
    foreach ($s in $succeeded) { Write-Host "    + $s" -ForegroundColor Green }
}

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "  Skipped ($($skipped.Count)):" -ForegroundColor Yellow
    foreach ($s in $skipped) { Write-Host "    ~ $s" -ForegroundColor Yellow }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "  Failed ($($failed.Count)):" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "    - $f" -ForegroundColor Red }
}

# Cleanup temp
if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
