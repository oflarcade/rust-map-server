# test-region-cache.ps1
# Tests worker-level GeoJSON cache (cold vs warm) and shared result cache for GET /region.
# Prereqs: docker compose -f tileserver/docker-compose.tenant.yml up; HDX data in hdx/ (e.g. nigeria_adm1/adm2).
# Always uses Nigeria (heavy GeoJSON). Default tenant 3 (nigeria-lagos-osun); or use 9, 14, 16, 18.
# Usage: .\scripts\test-region-cache.ps1 [-BaseUrl "http://localhost:8080"] [-TenantId 3]

param(
    [string]$BaseUrl = "http://localhost:8080",
    [string]$TenantId = "3"
)

$regionUrl = "$BaseUrl/region"
$lat1 = "6.4541"
$lon1 = "3.3947"
$lat2 = "6.5244"
$lon2 = "3.3792"
$header = @{ "X-Tenant-ID" = $TenantId }

function Get-RegionTimed {
    param([string]$Lat, [string]$Lon)
    $url = "${regionUrl}?lat=$Lat&lon=$Lon"
    # curl prints body then -w format; use newline so we can split body and time
    $raw = curl.exe -s -w "`n%{time_total}" -H "X-Tenant-ID: $TenantId" $url 2>&1
    $lines = $raw -split "`n"
    $time = $lines[-1].Trim()
    $body = ($lines[0..($lines.Count - 2)] -join "`n").Trim()
    return @{ Time = $time; Body = $body }
}

Write-Host "=== Region cache test (BaseUrl=$BaseUrl, X-Tenant-ID=$TenantId) ===" -ForegroundColor Cyan
Write-Host ""

# 1) Cold then warm (worker cache) + result cache
Write-Host "1. First request (cold worker + cold result cache) lat=$lat1 lon=$lon1"
$r1 = Get-RegionTimed -Lat $lat1 -Lon $lon1
Write-Host "   time_total=$($r1.Time)s" -ForegroundColor Yellow
Write-Host "   body: $($r1.Body)"
if ($r1.Body -match '"found"') { Write-Host "   OK (JSON with found)" } else { Write-Host "   WARN: unexpected body" }

Write-Host "2. Second request same coords (result cache hit)"
$r2 = Get-RegionTimed -Lat $lat1 -Lon $lon1
Write-Host "   time_total=$($r2.Time)s" -ForegroundColor Yellow
$resultHit = ($r2.Time -and [double]$r2.Time -lt 0.05)
if ($resultHit) { Write-Host "   OK (fast, result cache)" -ForegroundColor Green } else { Write-Host "   (may still be fast; result cache shared)" }

Write-Host "3. Different coords (warm worker, result cache miss) lat=$lat2 lon=$lon2"
$r3 = Get-RegionTimed -Lat $lat2 -Lon $lon2
Write-Host "   time_total=$($r3.Time)s" -ForegroundColor Yellow

Write-Host "4. Same coords again (result cache hit)"
$r4 = Get-RegionTimed -Lat $lat2 -Lon $lon2
Write-Host "   time_total=$($r4.Time)s" -ForegroundColor Yellow
if ([double]$r4.Time -lt 0.05) { Write-Host "   OK (sub-50ms, result cache)" -ForegroundColor Green }

# 2) Result cache: same request = same body
Write-Host ""
Write-Host "5. Result cache identity: two requests same coords -> same JSON"
$r5 = Get-RegionTimed -Lat $lat1 -Lon $lon1
$r6 = Get-RegionTimed -Lat $lat1 -Lon $lon1
$same = ($r5.Body -eq $r6.Body)
if ($same) { Write-Host "   OK (bodies identical)" -ForegroundColor Green } else { Write-Host "   FAIL (bodies differ)" -ForegroundColor Red }

Write-Host ""
Write-Host "Done. See tileserver/docs/testing-region-cache.md for full steps." -ForegroundColor Cyan
