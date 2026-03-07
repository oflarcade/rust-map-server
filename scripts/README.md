# Scripts

Scripts are grouped by shell:

| Directory   | Purpose                          |
|------------|-----------------------------------|
| `sh/`      | Bash scripts (macOS/Linux)        |
| `ps1/`     | PowerShell scripts (Windows)      |

Shared tooling (Node.js, Python) stays in `scripts/`:

- `split-boundaries.js` – split Nigeria boundaries into per-tenant GeoJSON
- `bounds-from-hdx.py` – derive state bounds from HDX GeoJSON
- `build-hdx-hierarchy.js` – HDX hierarchy helper
- `Dockerfile.tippecanoe` – build image for boundary PMTiles

**Run from repo root:**

- Bash: `./scripts/sh/setup.sh`, `./scripts/sh/generate-all.sh`, etc.
- PowerShell: `.\scripts\ps1\setup.ps1`, `.\scripts\ps1\generate-all.ps1`, etc.

See [CLAUDE.md](../CLAUDE.md) for full command reference.
