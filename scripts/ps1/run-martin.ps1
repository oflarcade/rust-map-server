#
# run-martin.ps1 - Start Martin tile server on Windows (port 3001)
# Usage: .\scripts\run-martin.ps1
#

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$ConfigFile = Join-Path $BaseDir "tileserver\martin-config-windows.yaml"
$PmtilesDir = Join-Path $BaseDir "pmtiles"
$BoundariesDir = Join-Path $BaseDir "boundaries"

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Martin Tile Server - Windows" -ForegroundColor Cyan
Write-Host "  Port: 3001" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Check Martin is installed
try {
    $martinVersion = & martin --version 2>&1
    Log-Success "Martin: $martinVersion"
} catch {
    Log-Error "'martin' command not found!"
    Write-Host ""
    Write-Host "  Install Martin with:" -ForegroundColor Yellow
    Write-Host "    cargo install martin" -ForegroundColor White
    Write-Host ""
    Write-Host "  Or download from:" -ForegroundColor Yellow
    Write-Host "    https://github.com/maplibre/martin/releases" -ForegroundColor White
    exit 1
}

# Check config exists
if (-not (Test-Path $ConfigFile)) {
    Log-Error "Config not found: $ConfigFile"
    exit 1
}

# Count available tiles
$detailedCount = (Get-ChildItem "$PmtilesDir\*-detailed.pmtiles" -ErrorAction SilentlyContinue).Count
$boundaryCount = (Get-ChildItem "$BoundariesDir\*.pmtiles" -ErrorAction SilentlyContinue).Count

if ($detailedCount -eq 0 -and $boundaryCount -eq 0) {
    Log-Error "No PMTiles files found!"
    Log-Info "Run .\scripts\generate-all.ps1 first"
    exit 1
}

Log-Info "Detailed tiles: $detailedCount files"
Log-Info "Boundary tiles: $boundaryCount files"

if ($detailedCount -eq 0) {
    Log-Warn "No detailed tiles found in pmtiles/ - only boundaries will be served"
    Log-Info "Run .\scripts\generate-all.ps1 to generate detailed tiles"
}

Write-Host ""
Log-Info "Config: $ConfigFile"
Log-Info "Starting Martin..."
Write-Host ""
Write-Host "  Catalog: http://localhost:3001/catalog" -ForegroundColor Green
Write-Host "  Health:  http://localhost:3001/health" -ForegroundColor Green
Write-Host ""
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

# cd to project root so relative paths in config work
Set-Location $BaseDir

# Start Martin
& martin --config $ConfigFile
