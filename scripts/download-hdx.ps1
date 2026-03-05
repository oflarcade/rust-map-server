#
# download-hdx.ps1 - Download HDX COD-AB administrative boundary GeoJSON for all countries
#
# HDX packages bundle all admin levels into a single <iso3>_admin_boundaries.geojson.zip.
# This script downloads that zip, extracts it, and copies the ADM1 + ADM2 GeoJSON files
# into hdx/<country>_adm1.geojson and hdx/<country>_adm2.geojson.
#
# India is excluded: no standard COD-AB package on HDX.
# Rwanda is excluded: HDX package has no GeoJSON (only SHP/EMF) -- see note below.
#
# License: CC BY-IGO (free for commercial use)
# Source:  https://data.humdata.org/
#
# Usage:
#   .\scripts\download-hdx.ps1
#   .\scripts\download-hdx.ps1 -Country kenya
#   .\scripts\download-hdx.ps1 -Force
#

param(
    [string]$Country = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$HdxDir  = Join-Path $BaseDir "hdx"

New-Item -ItemType Directory -Force -Path $HdxDir | Out-Null

function Log-Info    { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Success { param($msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Log-Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Error   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

# Country definitions. Package IDs follow cod-ab-<iso3-lowercase>.
# Rwanda excluded: its HDX package contains only SHP + EMF, no GeoJSON.
$Countries = @(
    @{ Name = "Nigeria";                  PackageId = "cod-ab-nga"; ShortName = "nigeria";                  Prefix = "nigeria"                  }
    @{ Name = "Kenya";                    PackageId = "cod-ab-ken"; ShortName = "kenya";                    Prefix = "kenya"                    }
    @{ Name = "Uganda";                   PackageId = "cod-ab-uga"; ShortName = "uganda";                   Prefix = "uganda"                   }
    @{ Name = "Liberia";                  PackageId = "cod-ab-lbr"; ShortName = "liberia";                  Prefix = "liberia"                  }
    @{ Name = "Central African Republic"; PackageId = "cod-ab-caf"; ShortName = "car";                      Prefix = "central-african-republic" }
)

if ($Country -ne "") {
    $Countries = $Countries | Where-Object { $_.ShortName -eq $Country -or $_.Prefix -eq $Country }
    if ($Countries.Count -eq 0) {
        Log-Error "Country '$Country' not found. Available: nigeria, kenya, uganda, liberia, car"
        Log-Warn  "(Rwanda excluded -- HDX package has no GeoJSON; India excluded -- no COD-AB package)"
        exit 1
    }
}

$HdxApiBase = "https://data.humdata.org/api/3/action"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Downloading HDX COD-AB boundary data (ADM1 + ADM2)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$succeeded = @()
$failed    = @()
$skipped   = @()

$total = $Countries.Count
$i = 0

foreach ($c in $Countries) {
    $i++
    Log-Info "[$i/$total] $($c.Name) ($($c.PackageId))..."

    $adm1Out = Join-Path $HdxDir "$($c.Prefix)_adm1.geojson"
    $adm2Out = Join-Path $HdxDir "$($c.Prefix)_adm2.geojson"

    if ((Test-Path $adm1Out) -and (Test-Path $adm2Out) -and -not $Force) {
        Log-Info "  Both ADM1 + ADM2 already exist - skipping (use -Force to re-download)"
        $skipped += $c.ShortName
        continue
    }

    # Fetch package metadata from HDX CKAN API
    $apiUrl = "$HdxApiBase/package_show?id=$($c.PackageId)"
    try {
        $response = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 30
        $pkg = ($response.Content | ConvertFrom-Json)
    } catch {
        Log-Error "  Failed to fetch package metadata from HDX: $_"
        $failed += "$($c.ShortName): API error"
        continue
    }

    if (-not $pkg.success) {
        Log-Error "  HDX API returned success=false for $($c.PackageId)"
        $failed += "$($c.ShortName): package not found"
        continue
    }

    $resources = $pkg.result.resources
    Log-Info "  Found $($resources.Count) resources in package"

    # HDX bundles all admin levels in one GeoJSON zip.
    # Match: format=GeoJSON (or name/url contains "geojson") AND url ends with .zip
    $zipResource = $resources | Where-Object {
        ($_.format -imatch "geojson") -and ($_.url -imatch "\.zip$")
    } | Select-Object -First 1

    if (-not $zipResource) {
        # Fallback: any zip with "geojson" in name or url
        $zipResource = $resources | Where-Object {
            ($_.name -imatch "geojson" -or $_.url -imatch "geojson") -and $_.url -imatch "\.zip$"
        } | Select-Object -First 1
    }

    if (-not $zipResource) {
        Log-Warn "  No GeoJSON zip resource found for $($c.Name). Available resources:"
        $resources | ForEach-Object { Log-Warn "    $($_.name) [$($_.format)] $($_.url)" }
        $failed += "$($c.ShortName): no GeoJSON zip found"
        continue
    }

    Log-Info "  GeoJSON zip: $($zipResource.name)"

    # Download zip to temp location
    $tempZip = Join-Path $env:TEMP "$($c.Prefix)_hdx_$(Get-Random).zip"
    $extractDir = Join-Path $env:TEMP "$($c.Prefix)_hdx_extract_$(Get-Random)"

    try {
        Log-Info "  Downloading zip..."
        Invoke-WebRequest -Uri $zipResource.url -OutFile $tempZip -UseBasicParsing -TimeoutSec 300
        $sz = (Get-Item $tempZip).Length
        Log-Success ("  Downloaded ({0:N1} MB)" -f ($sz / 1MB))
    } catch {
        Log-Error "  Failed to download zip: $_"
        if (Test-Path $tempZip) { Remove-Item $tempZip -ErrorAction SilentlyContinue }
        $failed += "$($c.ShortName): download error"
        continue
    }

    # Extract zip
    try {
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force
        Log-Info "  Extracted zip contents"
    } catch {
        Log-Error "  Failed to extract zip: $_"
        Remove-Item $tempZip -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -ErrorAction SilentlyContinue
        $failed += "$($c.ShortName): extract error"
        continue
    }

    # Find ADM1 and ADM2 GeoJSON files within the extracted directory
    # Typical naming: nga_admbnda_adm1_osgof_20190417.geojson
    $allJsonFiles = Get-ChildItem $extractDir -Recurse | Where-Object {
        $_.Extension -in @(".geojson", ".json") -and -not $_.PSIsContainer
    }
    Log-Info "  Found $($allJsonFiles.Count) JSON/GeoJSON files in zip"

    # Match admin1 / admin2 (not admin10, admin11, etc.) — files are named e.g. nga_admin1.geojson
    # Prefer non-_em variants (the _em suffix = emergency management simplified version)
    $adm1Candidates = $allJsonFiles | Where-Object { $_.Name -imatch "admin1[._]" }
    $adm2Candidates = $allJsonFiles | Where-Object { $_.Name -imatch "admin2[._]" }
    $adm1Extracted = ($adm1Candidates | Where-Object { $_.Name -notmatch "_em\." }) | Select-Object -First 1
    if (-not $adm1Extracted) { $adm1Extracted = $adm1Candidates | Select-Object -First 1 }
    $adm2Extracted = ($adm2Candidates | Where-Object { $_.Name -notmatch "_em\." }) | Select-Object -First 1
    if (-not $adm2Extracted) { $adm2Extracted = $adm2Candidates | Select-Object -First 1 }

    if (-not $adm1Extracted) {
        Log-Warn "  No admin1 file found in zip. Files present:"
        $allJsonFiles | ForEach-Object { Log-Warn "    $($_.Name)" }
        Remove-Item $tempZip -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -ErrorAction SilentlyContinue
        $failed += "$($c.ShortName): no admin1 file in zip"
        continue
    }
    if (-not $adm2Extracted) {
        Log-Warn "  No admin2 file found in zip. Files present:"
        $allJsonFiles | ForEach-Object { Log-Warn "    $($_.Name)" }
        Remove-Item $tempZip -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -ErrorAction SilentlyContinue
        $failed += "$($c.ShortName): no admin2 file in zip"
        continue
    }

    Log-Info "  ADM1 source: $($adm1Extracted.Name)"
    Log-Info "  ADM2 source: $($adm2Extracted.Name)"

    Copy-Item $adm1Extracted.FullName $adm1Out -Force
    Copy-Item $adm2Extracted.FullName $adm2Out -Force

    # Cleanup temp files
    Remove-Item $tempZip -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -ErrorAction SilentlyContinue

    $adm1Sz = (Get-Item $adm1Out).Length
    $adm2Sz = (Get-Item $adm2Out).Length
    Log-Success ("  ADM1 -> $($c.Prefix)_adm1.geojson ({0:N1} MB)" -f ($adm1Sz / 1MB))
    Log-Success ("  ADM2 -> $($c.Prefix)_adm2.geojson ({0:N1} MB)" -f ($adm2Sz / 1MB))

    $succeeded += $c.ShortName
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  HDX Download Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($succeeded.Count -gt 0) { Write-Host "Downloaded: $($succeeded -join ', ')" -ForegroundColor Green }
if ($skipped.Count -gt 0)   { Write-Host "Skipped:   $($skipped -join ', ')" -ForegroundColor Yellow }
if ($failed.Count -gt 0)    { Write-Host "Failed:    $($failed -join ', ')" -ForegroundColor Red }

Write-Host ""
Log-Warn "Rwanda excluded: its HDX package has no GeoJSON (only SHP). HDX boundary comparison unavailable for Rwanda."
Log-Warn "India excluded: no COD-AB package on HDX."

if ($succeeded.Count -gt 0) {
    Write-Host ""
    Log-Info "Next step: generate PMTiles with:"
    Log-Info "  .\scripts\generate-hdx-boundaries.ps1"
}

Write-Host ""
Get-ChildItem "$HdxDir\*.geojson" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  + {0} ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) -ForegroundColor Green
}

if ($failed.Count -gt 0) { exit 1 }
