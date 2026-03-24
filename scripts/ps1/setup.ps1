#
# setup.ps1 - Windows Setup: Install prerequisites and download Planetiler + OSM data
# Usage: .\scripts\setup.ps1
#

$ErrorActionPreference = "Stop"

# Configuration
$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$PlanetilerVersion = "0.7.0"
$PlanetilerJar = Join-Path $BaseDir "planetiler.jar"
$OsmDataDir = Join-Path $BaseDir "osm-data"
$BoundariesDir = Join-Path $BaseDir "boundaries"
$PmtilesDir = Join-Path $BaseDir "pmtiles"
$DataSourcesDir = Join-Path $BaseDir "data\sources"
$TempDir = Join-Path $BaseDir "temp"

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Log-Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Error   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Step    { param($msg) Write-Host "[STEP] $msg" -ForegroundColor Cyan }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PMTiles Generation Pipeline - Windows Setup Script" -ForegroundColor Cyan
Write-Host "  (OSM base maps + HDX/OSM boundaries)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Set-Location $BaseDir
Log-Info "Working directory: $BaseDir"

# ── Step 1: Check Java ──────────────────────────────────────────────
Log-Step "Step 1/5: Checking Java installation..."
# Ensure Adoptium / common JDK install paths are on PATH for this session
$adoptiumRoot = "C:\Program Files\Eclipse Adoptium"
if (Test-Path $adoptiumRoot) {
    $jdkBin = Get-ChildItem $adoptiumRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($jdkBin) {
        $env:PATH = "$($jdkBin.FullName)\bin;$env:PATH"
        $env:JAVA_HOME = $jdkBin.FullName
    }
}
try {
    # java -version writes to stderr; use Continue to prevent Stop-mode treating it as fatal
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $javaVersionOutput = & java -version 2>&1 | Select-Object -First 1
    $ErrorActionPreference = $prev
    $javaVersionMatch = [regex]::Match([string]$javaVersionOutput, '"(\d+)')
    if ($javaVersionMatch.Success) {
        $javaMajor = [int]$javaVersionMatch.Groups[1].Value
        if ($javaMajor -ge 17) {
            Log-Success "Java $javaMajor detected (17+ required)"
        } else {
            Log-Warn "Java $javaMajor detected. Java 17+ required."
            Log-Info "Install with: winget install EclipseAdoptium.Temurin.17.JDK"
            exit 1
        }
    } else {
        Log-Error "Java not found. Install Java 17+:"
        Write-Host "  winget install EclipseAdoptium.Temurin.17.JDK" -ForegroundColor White
        exit 1
    }
} catch {
    Log-Error "Java not found. Install Java 17+:"
    Write-Host "  winget install EclipseAdoptium.Temurin.17.JDK" -ForegroundColor White
    exit 1
}

# ── Step 2: Check Martin ────────────────────────────────────────────
Log-Step "Step 2/5: Checking Martin installation..."
try {
    $martinVersion = & martin --version 2>&1
    Log-Success "Martin installed: $martinVersion"
} catch {
    Log-Warn "Martin not found. Install with: cargo install martin"
    Log-Info "Martin is needed to serve tiles (Step 2 of the pipeline)"
}

# ── Step 3: Download Planetiler ─────────────────────────────────────
Log-Step "Step 3/5: Downloading Planetiler v$PlanetilerVersion..."
if (Test-Path $PlanetilerJar) {
    $size = (Get-Item $PlanetilerJar).Length / 1MB
    Log-Success ("Planetiler already exists ({0:N1} MB)" -f $size)
} else {
    $url = "https://github.com/onthegomap/planetiler/releases/download/v$PlanetilerVersion/planetiler.jar"
    Log-Info "Downloading from: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $PlanetilerJar -UseBasicParsing
        $size = (Get-Item $PlanetilerJar).Length / 1MB
        Log-Success ("Planetiler downloaded ({0:N1} MB)" -f $size)
    } catch {
        Log-Error "Failed to download Planetiler: $_"
        exit 1
    }
}

# ── Step 4: Create directories ──────────────────────────────────────
Log-Step "Step 4/5: Setting up directories..."
foreach ($dir in @($OsmDataDir, $PmtilesDir, $BoundariesDir, $DataSourcesDir, $TempDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
Log-Success "Directories ready"

# ── Step 5: Download OSM extracts ───────────────────────────────────
Log-Step "Step 5/5: Downloading OSM extracts from Geofabrik..."

$countries = @(
    @{ Name = "liberia";                    Url = "https://download.geofabrik.de/africa/liberia-latest.osm.pbf" },
    @{ Name = "rwanda";                     Url = "https://download.geofabrik.de/africa/rwanda-latest.osm.pbf" },
    @{ Name = "central-african-republic";   Url = "https://download.geofabrik.de/africa/central-african-republic-latest.osm.pbf" },
    @{ Name = "uganda";                     Url = "https://download.geofabrik.de/africa/uganda-latest.osm.pbf" },
    @{ Name = "kenya";                      Url = "https://download.geofabrik.de/africa/kenya-latest.osm.pbf" },
    @{ Name = "nigeria";                    Url = "https://download.geofabrik.de/africa/nigeria-latest.osm.pbf" },
    @{ Name = "india";                      Url = "https://download.geofabrik.de/asia/india-latest.osm.pbf" }
)

$total = $countries.Count
$i = 0

foreach ($country in $countries) {
    $i++
    $outputFile = Join-Path $OsmDataDir "$($country.Name)-latest.osm.pbf"

    if (Test-Path $outputFile) {
        $size = (Get-Item $outputFile).Length / 1MB
        Log-Info ("[$i/$total] $($country.Name) already downloaded ({0:N1} MB) - skipping" -f $size)
    } else {
        Log-Info "[$i/$total] Downloading $($country.Name)..."
        try {
            Invoke-WebRequest -Uri $country.Url -OutFile $outputFile -UseBasicParsing
            $size = (Get-Item $outputFile).Length / 1MB
            Log-Success ("{0} downloaded ({1:N1} MB)" -f $country.Name, $size)
        } catch {
            Log-Error "Failed to download $($country.Name): $_"
        }
    }
}

# ── Summary ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "                    Setup Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

Log-Info "Downloaded OSM files:"
Get-ChildItem "$OsmDataDir\*.osm.pbf" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  + {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) -ForegroundColor Green
}

Write-Host ""
Log-Info "Existing boundary tiles:"
Get-ChildItem "$BoundariesDir\*.pmtiles" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  + {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) -ForegroundColor Green
}

Write-Host ""
Log-Info "Next steps:"
Log-Info "  1. Generate tiles:  .\scripts\generate-all.ps1"
Log-Info "  2. Or single:       .\scripts\generate-single.ps1 nigeria"
Log-Info "  3. Run Martin:      .\scripts\run-martin.ps1"
