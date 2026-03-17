#
# download-inec.ps1 - Download Nigeria INEC electoral boundary GeoJSON from HDX
#
# Attempts to download Nigeria electoral boundaries (senatorial zones + federal
# constituencies) from HDX. Tries multiple known package IDs.
#
# If auto-download fails, prints manual placement instructions.
# Files must end up in data/inec/ for import by import-inec-to-pg.js.
#
# Usage:
#   .\scripts\ps1\download-inec.ps1
#   .\scripts\ps1\download-inec.ps1 -Force
#   .\scripts\ps1\download-inec.ps1 -Search     # just search HDX and print results
#

param(
    [switch]$Force,
    [switch]$Search
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$InecDir = Join-Path $BaseDir "data\inec"

New-Item -ItemType Directory -Force -Path $InecDir | Out-Null

function Log-Info    { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Log-Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Error   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

$HdxApiBase = "https://data.humdata.org/api/3/action"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Nigeria INEC Electoral Boundaries downloader" -ForegroundColor Cyan
Write-Host "  Target: $InecDir" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# -Search mode: query HDX and print matching packages so you can find the ID
# ---------------------------------------------------------------------------
if ($Search) {
    Log-Info "Searching HDX for Nigeria electoral boundary datasets..."
    $SearchUrl = "$HdxApiBase/package_search?q=nigeria+electoral+senatorial+boundaries&rows=10"
    try {
        $SearchResponse = Invoke-RestMethod -Uri $SearchUrl -Method Get -TimeoutSec 30
        if ($SearchResponse.success -and $SearchResponse.result.results.Count -gt 0) {
            Write-Host "`nMatching HDX packages:" -ForegroundColor Cyan
            foreach ($pkg in $SearchResponse.result.results) {
                Write-Host "  ID:    $($pkg.id)"   -ForegroundColor White
                Write-Host "  Name:  $($pkg.name)" -ForegroundColor White
                Write-Host "  Title: $($pkg.title)" -ForegroundColor Gray
                Write-Host ""
            }
            Write-Host "Re-run with the correct package name:" -ForegroundColor Yellow
            Write-Host "  Set `$PackageIds in this script and re-run, or place files manually." -ForegroundColor Yellow
        } else {
            Log-Warn "No results found. Try visiting:"
            Log-Warn "  https://data.humdata.org/dataset?q=nigeria+electoral+senatorial"
        }
    } catch {
        Log-Error "Search failed: $_"
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Package IDs to try in order
# ---------------------------------------------------------------------------
# The plan referenced 'nigeria-electoral-boundaries' which does not exist on HDX.
# cod-ab-nga (Nigeria COD-AB) sometimes contains adm3 electoral boundaries.
# Add other known IDs here as they are discovered.
$PackageIds = @(
    "nigeria-electoral-boundaries",
    "cod-ab-nga",
    "nigeria-independent-national-electoral-commission-lga-and-wards"
)

# Keywords that identify senatorial / constituency resources
$TargetMappings = @(
    @{ Keywords = @("senat", "senatorial", "sen_zone", "senate"); Output = "nigeria_senatorial.geojson" }
    @{ Keywords = @("constit", "constituency", "fed_const", "federal_constituency"); Output = "nigeria_constituencies.geojson" }
)

$Downloaded = 0

function Try-Package {
    param($PkgId)

    Log-Info "Trying package '$PkgId'..."
    $PackageUrl = "$HdxApiBase/package_show?id=$PkgId"
    try {
        $Resp = Invoke-RestMethod -Uri $PackageUrl -Method Get -TimeoutSec 30
    } catch {
        Log-Warn "  Package '$PkgId' not found: $_"
        return 0
    }

    if (-not $Resp.success) {
        Log-Warn "  Package '$PkgId': API returned success=false"
        return 0
    }

    $Resources = $Resp.result.resources
    Log-Info "  Found $($Resources.Count) resource(s) in package '$PkgId'"

    $found = 0

    foreach ($res in $Resources) {
        $resName = $res.name.ToLower()

        if ($res.format) { $resFormat = $res.format.ToLower() } else { $resFormat = "" }
        if ($res.download_url) { $resUrl = $res.download_url } else { $resUrl = $res.url }
        if (-not $resUrl) { continue }

        $isGeoJson = ($resFormat -eq "geojson") -or $resUrl.EndsWith(".geojson")
        $isZip     = ($resFormat -eq "zip")     -or $resUrl.EndsWith(".zip")
        $isJson    = ($resFormat -eq "json")    -or $resUrl.EndsWith(".json")
        if (-not ($isGeoJson -or $isZip -or $isJson)) { continue }

        foreach ($mapping in $TargetMappings) {
            $matched = $false
            foreach ($kw in $mapping.Keywords) {
                if ($resName -like "*$kw*") { $matched = $true; break }
            }
            if (-not $matched) { continue }

            $OutputFile = Join-Path $InecDir $mapping.Output

            if ((Test-Path $OutputFile) -and -not $Force) {
                Log-Info "  $($mapping.Output) already exists (use -Force to re-download)"
                $found++
                continue
            }

            Log-Info "  Downloading: $($res.name) -> $($mapping.Output)"

            $TmpFile = Join-Path $env:TEMP ("inec_" + [System.IO.Path]::GetRandomFileName())

            try {
                Invoke-WebRequest -Uri $resUrl -OutFile $TmpFile -TimeoutSec 120
            } catch {
                Log-Warn "  Download failed for '$($res.name)': $_"
                if (Test-Path $TmpFile) { Remove-Item $TmpFile -Force }
                continue
            }

            # Detect ZIP by magic bytes
            $isZipFile = $false
            if ($resUrl.EndsWith(".zip")) {
                $isZipFile = $true
            } else {
                $bytes = [System.IO.File]::ReadAllBytes($TmpFile)
                if ($bytes.Length -ge 2 -and $bytes[0] -eq 80 -and $bytes[1] -eq 75) {
                    $isZipFile = $true
                }
            }

            if ($isZipFile) {
                Log-Info "  Extracting ZIP..."
                $ExtractDir = Join-Path $env:TEMP ("inec_extract_" + [System.IO.Path]::GetRandomFileName())
                New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null

                try {
                    Expand-Archive -Path $TmpFile -DestinationPath $ExtractDir -Force
                    $GeoJsonFiles = Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.geojson"
                    if ($GeoJsonFiles.Count -eq 0) {
                        $GeoJsonFiles = Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.json"
                    }
                    if ($GeoJsonFiles.Count -eq 0) {
                        Log-Warn "  No GeoJSON found in ZIP (may be shapefile only)"
                    } else {
                        $BestFile = $GeoJsonFiles[0]
                        foreach ($gj in $GeoJsonFiles) {
                            foreach ($kw in $mapping.Keywords) {
                                if ($gj.Name.ToLower() -like "*$kw*") { $BestFile = $gj; break }
                            }
                        }
                        Copy-Item -Path $BestFile.FullName -Destination $OutputFile -Force
                        Log-Success "  Extracted $($BestFile.Name) -> $($mapping.Output)"
                        $found++
                    }
                } finally {
                    Remove-Item $TmpFile -Force -ErrorAction SilentlyContinue
                    Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Copy-Item -Path $TmpFile -Destination $OutputFile -Force
                Remove-Item $TmpFile -Force -ErrorAction SilentlyContinue
                Log-Success "  Saved $($mapping.Output)"
                $found++
            }
        }
    }

    return $found
}

foreach ($pkgId in $PackageIds) {
    $n = Try-Package -PkgId $pkgId
    $Downloaded += $n
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan

$senatFile  = Join-Path $InecDir "nigeria_senatorial.geojson"
$constitFile = Join-Path $InecDir "nigeria_constituencies.geojson"
$haveSenat  = Test-Path $senatFile
$haveConst  = Test-Path $constitFile

if ($haveSenat -and $haveConst) {
    Log-Success "Both INEC files are present in $InecDir"
    Write-Host ""
    Write-Host "  Next: node scripts/import-inec-to-pg.js" -ForegroundColor Green
    Write-Host "  Jigawa only: node scripts/import-inec-to-pg.js --state NG018" -ForegroundColor Green
} else {
    Log-Warn "Auto-download did not produce all required files."
    Log-Warn "Files needed in $InecDir :"
    if (-not $haveSenat) {
        Log-Warn "  MISSING: nigeria_senatorial.geojson  (senatorial districts, adm3)"
    } else {
        Log-Success "  PRESENT: nigeria_senatorial.geojson"
    }
    if (-not $haveConst) {
        Log-Warn "  MISSING: nigeria_constituencies.geojson  (federal constituencies, adm4)"
    } else {
        Log-Success "  PRESENT: nigeria_constituencies.geojson"
    }

    Write-Host ""
    Write-Host "Manual steps to obtain these files:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Option 1 - HDX search (find correct package ID):" -ForegroundColor White
    Write-Host "    .\scripts\ps1\download-inec.ps1 -Search" -ForegroundColor Gray
    Write-Host "    https://data.humdata.org/dataset?q=nigeria+senatorial+electoral" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Option 2 - Nigeria COD-AB adm3 (wards, some states only):" -ForegroundColor White
    Write-Host "    Already downloaded by download-hdx.ps1 as hdx\nigeria_adm3.geojson" -ForegroundColor Gray
    Write-Host "    Copy and rename: nigeria_senatorial.geojson (adjust field names)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Option 3 - GRID3 Nigeria (wards/electoral):" -ForegroundColor White
    Write-Host "    https://grid3.org/resources/results?q=nigeria" -ForegroundColor Gray
    Write-Host "    Download GeoJSON, rename, place in data\inec\" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  GeoJSON property requirements (used by import-inec-to-pg.js):" -ForegroundColor White
    Write-Host "    Senatorial:     sen_pcode (or pcode), sen_name (or name), adm1_pcode" -ForegroundColor Gray
    Write-Host "    Constituencies: con_pcode (or pcode), con_name (or name), sen_pcode" -ForegroundColor Gray
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
