#
# generate-all.ps1 - Generate PMTiles for all 7 countries on Windows
# Usage: .\scripts\generate-all.ps1
#
# Generates tiles in order from smallest to largest:
#   1. Liberia       (~2 min,  2GB RAM)
#   2. Rwanda        (~3 min,  2GB RAM)
#   3. CAR           (~3 min,  2GB RAM)
#   4. Uganda        (~10 min, 4GB RAM)
#   5. Kenya         (~15 min, 4GB RAM)
#   6. Nigeria       (~30 min, 6GB RAM)
#   7. India         (~90 min, 8GB RAM)
#

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GenerateSingle = Join-Path $ScriptDir "generate-single.ps1"

# Colors
function Log-Info    { param($msg) Write-Host "[INFO] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Red }

$countries = @(
    "liberia",
    "rwanda",
    "central-african-republic",
    "uganda",
    "kenya",
    "nigeria",
    "india"
)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Generating PMTiles for ALL countries" -ForegroundColor Cyan
Write-Host "  Total: $($countries.Count) countries" -ForegroundColor Cyan
Write-Host "  Estimated time: 2-3 hours (depending on hardware)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$succeeded = @()
$failed = @()

$i = 0
foreach ($country in $countries) {
    $i++
    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Log-Info "[$i/$($countries.Count)] Starting: $($country.ToUpper())"
    Write-Host "────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    try {
        & $GenerateSingle $country
        $succeeded += $country
        Log-Success "$($country.ToUpper()) done"
    } catch {
        Log-Error "Failed to generate $($country.ToUpper()): $_"
        $failed += $country
    }
}

$totalStopwatch.Stop()
$totalElapsed = $totalStopwatch.Elapsed

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Generation Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Total time: $([math]::Floor($totalElapsed.TotalHours))h $($totalElapsed.Minutes)m $($totalElapsed.Seconds)s" -ForegroundColor White
Write-Host ""

if ($succeeded.Count -gt 0) {
    Write-Host "  Succeeded ($($succeeded.Count)):" -ForegroundColor Green
    foreach ($c in $succeeded) {
        Write-Host "    + $c" -ForegroundColor Green
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "  Failed ($($failed.Count)):" -ForegroundColor Red
    foreach ($c in $failed) {
        Write-Host "    - $c" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Re-run failed countries individually:" -ForegroundColor Yellow
    foreach ($c in $failed) {
        Write-Host "    .\scripts\generate-single.ps1 $c" -ForegroundColor White
    }
}

# Show generated files
$BaseDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$PmtilesDir = Join-Path $BaseDir "pmtiles"
Write-Host ""
Log-Info "Generated PMTiles:"
Get-ChildItem "$PmtilesDir\*-detailed.pmtiles" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  + {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) -ForegroundColor Green
}

Write-Host ""
Log-Info "Next step: .\scripts\run-martin.ps1"
