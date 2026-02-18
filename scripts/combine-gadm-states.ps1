#
# combine-gadm-states.ps1 - Combine multiple GADM state polygons into one GeoJSON FeatureCollection
#
# Usage: .\scripts\combine-gadm-states.ps1 -GadmFile gadm\nigeria_2.json -OutputFile gadm\states\lagos-osun.json -States Lagos,Osun
#

param(
    [Parameter(Mandatory=$true)]
    [string]$GadmFile,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$true)]
    [string[]]$States
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $GadmFile)) {
    Write-Host "[ERROR] GADM file not found: $GadmFile" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Reading $GadmFile ..." -ForegroundColor Blue

$statesJson = ($States | ForEach-Object { "'$_'" }) -join ','

$result = & python -c @"
import json, sys
with open(r'$GadmFile') as f:
    data = json.load(f)
targets = [$statesJson]
features = [f for f in data['features'] if f['properties']['NAME_1'] in targets]
found = set(f['properties']['NAME_1'] for f in features)
missing = [t for t in targets if t not in found]
if missing:
    print('ERROR:States not found: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(1)
out = {'type': 'FeatureCollection', 'features': features}
with open(r'$OutputFile', 'w') as f:
    json.dump(out, f)
print(f'OK:{len(features)} features from {len(found)} states')
"@

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to combine states" -ForegroundColor Red
    exit 1
}

Write-Host "[SUCCESS] $result -> $OutputFile" -ForegroundColor Green
