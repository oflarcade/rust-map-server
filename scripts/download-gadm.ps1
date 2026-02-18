#
# download-gadm.ps1 - Download GADM administrative boundary data for all countries
#

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$GadmDir = Join-Path $BaseDir "gadm"

New-Item -ItemType Directory -Force -Path $GadmDir | Out-Null

function Log-Info    { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Log-Error   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

# Country name → ISO3 code mapping
$Countries = @(
    @{ Name = "nigeria";                  ISO = "NGA" }
    @{ Name = "kenya";                    ISO = "KEN" }
    @{ Name = "uganda";                   ISO = "UGA" }
    @{ Name = "rwanda";                   ISO = "RWA" }
    @{ Name = "liberia";                  ISO = "LBR" }
    @{ Name = "central-african-republic"; ISO = "CAF" }
    @{ Name = "india";                    ISO = "IND" }
)

# GADM 4.1 GeoJSON download base URL
$BaseUrl = "https://geodata.ucdavis.edu/gadm/gadm4.1/json"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Downloading GADM boundary data (levels 0, 1, and 2)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$total = $Countries.Count
$i = 0

foreach ($c in $Countries) {
    $i++
    Log-Info "[$i/$total] $($c.Name) ($($c.ISO))..."

    # Download all available levels (0-4)
    for ($level = 0; $level -le 4; $level++) {
        $outFile = Join-Path $GadmDir "$($c.Name)_$level.json"
        $url = "$BaseUrl/gadm41_$($c.ISO)_$level.json"

        if (Test-Path $outFile) {
            Log-Info "  Level $level already exists - skipping"
        } else {
            try {
                Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
                $sz = (Get-Item $outFile).Length
                if ($sz -gt 1MB) {
                    Log-Success ("  Level $level downloaded ({0:N1} MB)" -f ($sz / 1MB))
                } else {
                    Log-Success ("  Level $level downloaded ({0:N0} KB)" -f ($sz / 1KB))
                }
            } catch {
                Log-Info "  Level $level not available or download failed"
            }
        }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  GADM Download Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

Get-ChildItem "$GadmDir\*.json" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  + {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) -ForegroundColor Green
}
