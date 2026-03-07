#
# generate-lagos-osun.ps1 - Generate combined Lagos + Osun tiles for tenant 3
#

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PlanetilerJar = Join-Path $BaseDir "planetiler.jar"
$OsmFile = Join-Path $BaseDir "osm-data\nigeria-latest.osm.pbf"
$OutputFile = Join-Path $BaseDir "pmtiles\terrain\nigeria-lagos-osun.pmtiles"
$DataSourcesDir = Join-Path $BaseDir "data\sources"
$TempDir = Join-Path $BaseDir "temp"

# ── Safety checks ──────────────────────────────────────────
if (-not (Test-Path $PlanetilerJar)) {
    Write-Host "[ERROR] Planetiler not found: $PlanetilerJar" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OsmFile)) {
    Write-Host "[ERROR] OSM file not found: $OsmFile" -ForegroundColor Red
    Write-Host "[INFO]  Re-download: Invoke-WebRequest -Uri 'https://download.geofabrik.de/africa/nigeria-latest.osm.pbf' -OutFile '$OsmFile'" -ForegroundColor Blue
    exit 1
}

if ((Test-Path $OutputFile) -and ((Get-Item $OutputFile).Length -gt 0)) {
    $existingSize = (Get-Item $OutputFile).Length / 1MB
    Write-Host "[INFO] Already exists: $OutputFile ({0:N1} MB) - skipping. Delete file to regenerate." -f $existingSize -ForegroundColor Blue
    exit 0
}

# ── Create directories ─────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile), $DataSourcesDir, $TempDir | Out-Null

# ── Verify tmpdir is absolute and not project root ─────────
if ($TempDir -eq $BaseDir) {
    Write-Host "[ERROR] tmpdir must not be the project root!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Generating combined Lagos + Osun tiles (tenant 3)..." -ForegroundColor Cyan
Write-Host "  OSM input:  $OsmFile" -ForegroundColor White
Write-Host "  Output:     $OutputFile" -ForegroundColor White
Write-Host "  TempDir:    $TempDir" -ForegroundColor White
Write-Host "  SourcesDir: $DataSourcesDir" -ForegroundColor White
Write-Host ""

& java -Xmx6g -jar $PlanetilerJar `
    --osm-path="$OsmFile" `
    --output="$OutputFile" `
    --download `
    --download_dir="$DataSourcesDir" `
    --force `
    --bounds="2.696300,6.363200,5.074400,8.094700" `
    --maxzoom=14 `
    --minzoom=10 `
    --simplify-tolerance-at-max-zoom=0.1 `
    --only-layers=water,landuse,landcover,place `
    --nodemap-type=sparsearray `
    --storage=ram `
    --nodemap-storage=ram `
    --osm_lazy_reads=false `
    --tmpdir="$TempDir"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Planetiler failed with exit code $LASTEXITCODE" -ForegroundColor Red
    exit 1
}

if ((Test-Path $OutputFile) -and ((Get-Item $OutputFile).Length -gt 0)) {
    $size = (Get-Item $OutputFile).Length / 1MB
    Write-Host ""
    Write-Host ("[SUCCESS] Lagos+Osun tiles generated ({0:N1} MB)" -f $size) -ForegroundColor Green
} else {
    Write-Host "[ERROR] No output file produced" -ForegroundColor Red
    exit 1
}

# Cleanup temp
if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
