# Session notes — 2026-03-23

This document summarizes work completed in this session and records the **Martin / PMTiles layout** issue that caused repeated 404s and confusion despite “all Nigeria states” being generated or uploaded.

---

## 1. Nginx + OpenResty: tenant validation and crash fix

### Problem

- **`INVALID_TENANT_ID` (400)** on `/boundaries/hierarchy`, `/boundaries/geojson`, etc. for **DB-only tenants** (e.g. tenant 21): nginx `if ($tenant_source = "")` could run **before** `rewrite_by_lua` in the same `location`, so `$tenant_source` was still empty when the `if` evaluated.

### Fix

- **`tileserver/lua/validate-tenant.lua`** — access-phase checks: `X-Tenant-ID`, `tenant_source`, and for Martin boundary routes `boundary_source` (404 `NO_BOUNDARY_DATA` when missing).
- **`tileserver/nginx-tenant-proxy.conf`** — removed those `if` checks from locations; added **`access_by_lua_file validate-tenant.lua`** after **`resolve-tenant.lua`** where only validation was needed (`/tiles.json`, `/boundaries.json`).

### Follow-up bug: duplicate `access_by_lua_file`

- OpenResty allows **only one** `access_by_lua_file` per `location`.
- We had added **`validate-tenant.lua`** and **`origin-whitelist.lua`** as two directives → nginx **emerg**: `directive is duplicate` → **`tileserver_nginx_1` crash loop** → **502** on all API routes, **`curl` to :8080 failed**.
- **Fix:** **`tileserver/lua/access-validate-and-origin.lua`** — single handler: **OPTIONS first** (CORS preflight), then tenant validation, then origin whitelist logic (same allowlist as before).
- Locations that need both now use **only** `access-validate-and-origin.lua`. **`origin-whitelist.lua`** remains for `/admin/states` and `/admin/tenants` (no tenant resolution).

### Deploy

- **`scripts/sh/deploy-gcp-lua.sh`** — includes `validate-tenant.lua`, `access-validate-and-origin.lua`, `tile-source-normalize.lua`, etc.
- **`scripts/sh/gcp-rename-boundaries-redeploy.sh`** — rename `*-admin.pmtiles` → `*-boundaries`, upload Lua + nginx, restart; uses **`docker-compose`** (v1) on the VM (`docker compose` plugin not available).

---

## 2. Naming: `-boundaries` vs `-admin` (generate-states vs Add Tenant)

### Problem

- **Add Tenant** wizard derives **`nigeria-{state}-boundaries`** for Martin boundary sources.
- **`generate-states.sh` / `generate-states.ps1`** previously wrote **`nigeria-{state}-admin.pmtiles`**, so Martin exposed **`nigeria-delta-admin`**, not **`nigeria-delta-boundaries`** → 404 when DB pointed at `-boundaries`.

### Fix (repo)

- **`scripts/sh/generate-states.sh`** and **`scripts/ps1/generate-states.ps1`** — boundary outputs renamed to **`*-boundaries.pmtiles`** and combined file **`nigeria-states-boundaries.pmtiles`** (was `*-admin`).
- **`tileserver/lua/tile-source-normalize.lua`** — on **`POST /admin/tenants`**, **`nigeria-*-admin`** → **`nigeria-*-boundaries`** for stored `boundary_source`.
- **`View/src/lib/martinSources.ts`** — shared helpers: **`deriveNigeriaMartinSources`**, etc.; **`AddTenantWizard.vue`** uses them.
- **`.github/copilot-instructions.md`** — wording updated for state boundary filenames.

---

## 3. Add Tenant UX: Create button disabled

### Problem

- **`canCreate`** required non-empty **Tenant name** even when Nigeria + state scope was already selected.

### Fix

- **`effectiveTenantName`** — if the user leaves the name empty for **NG/IN** and has states selected, default to e.g. **`Bridge Adamawa`**; submit uses that for `country_name`.
- Placeholder + hint: **“Will use: …”** when the default applies.

---

## 4. Frontend: Martin URL (connection refused to localhost)

### Problem

- Production build used **`DEFAULT_MARTIN_URL` → `http://localhost:3000`** when **`VITE_MARTIN_URL`** was unset → browser requested tile JSON from **the user’s laptop** → **`ERR_CONNECTION_REFUSED`** for `kenya-detailed`, etc.

### Fix

- **`View/src/config/urls.ts`** — **`inferMartinBaseUrl()`**: if **`VITE_MARTIN_URL`** is unset but **`VITE_PROXY_URL`** is set, use **same host, port 3000** (Martin).

Production builds should still set **`VITE_PROXY_URL`** and **`VITE_MARTIN_URL`** explicitly to the VM (e.g. `http://<IP>:8080` and `http://<IP>:3000`).

---

## 5. GCP helpers and defaults

| Script | Purpose |
|--------|--------|
| **`scripts/sh/gcp-upload-nigeria-state-pmtiles.sh`** | Upload one state’s **`pmtiles/<profile>/nigeria-<slug>.pmtiles`** and boundary (`*-boundaries` or legacy `*-admin` → remote `*-boundaries`), restart Martin. |
| **`scripts/sh/gcp-rename-boundaries-redeploy.sh`** | Rename legacy `*-admin` in `data/boundaries`, upload nginx + Lua, restart martin + nginx. |
| **`scripts/sh/flatten-pmtiles-for-martin.sh`** | Copy `*.pmtiles` from **`data/pmtiles/{full,z6,terrain}`** and **`data/boundaries/{full,z6}`** into top-level **`data/pmtiles/`** / **`data/boundaries/`** when basename not already present. |
| **`scripts/sh/deploy-gcp-lua.sh`**, **`deploy-gcp-view.sh`** | Default **`GCP_REMOTE_BASE=/home/omarlakhdhar_gmail_com/rust-map-server`** (GCE user home ≠ laptop user). |

---

## 6. Martin configuration: multiple paths and failures

### What we changed

- **`tileserver/martin-config.yaml`** — besides **`/data/pmtiles`** and **`/data/boundaries`**, added **`/data/pmtiles/z6`** so state tiles under **`z6/`** are discoverable without copying to the top level first.
- **Commented** optional paths (**`full`**, **`terrain`**, **`boundaries/full`**) — **only uncomment after the directory exists on the host**; otherwise Martin **exits** with e.g. **`Source path is not a file: /data/pmtiles/full`** and the container restarts forever.

### Duplicates: `z6/` vs top-level

- If the **same basename** exists in **`/data/pmtiles/`** and **`/data/pmtiles/z6/`**, Martin registers a second source as **`nigeria-lagos.1`**, etc. Tenants must use the **canonical** id (**`nigeria-lagos`**) — usually the **top-level** file.
- On the VM, duplicate **`z6/`** copies were removed when the same name existed at the top.

---

## 7. Latest issue (documented): “All Nigeria states uploaded” but 404 / not all sources

### Symptoms

- New tenant (e.g. **Bridge Abia**, `nigeria-abia` / `nigeria-abia-boundaries`) → **404** on **`GET {MARTIN_URL}/nigeria-abia`** and boundary metadata.
- User belief: **all states** were uploaded to the VM; repeated per-state uploads and confusion.

### Root cause

1. **Martin does not walk subdirectories recursively** under a single path. Each entry under **`pmtiles.paths`** is one directory whose **`*.pmtiles`** files become catalog sources (basename without extension).
2. **Local `generate-states`** writes to **`pmtiles/<profile>/`** (e.g. **`pmtiles/full/`**). If the VM only has files under **`data/pmtiles/full/`** but that path is **not** in **`martin-config.yaml`** (or the directory **does not exist**), Martin **never** exposes those sources.
3. **Partial coverage on the VM** — at one check: only **~8** Nigeria base maps at **`data/pmtiles/`** top level, **6** in **`z6/`** (overlapping names), **not** 37 states. Bulk “full set” may exist on a **laptop** or in a **zip**, but **not** flattened into the directories Martin reads on GCE.
4. **Creating a tenant** only updates **PostgreSQL** (`tile_source`, `boundary_source`). It does **not** copy PMTiles onto disk — **Martin must already serve** those source ids.

### Operational checklist

1. **Verify catalog** on the VM:  
   `curl -s http://127.0.0.1:3000/catalog | grep nigeria-<state>`  
   (or inspect JSON for exact source ids).
2. **Either:**
   - Copy **`pmtiles/full/*.pmtiles`** → **`data/pmtiles/`** (use **`flatten-pmtiles-for-martin.sh`** then rsync/scp), **or**
   - **`mkdir -p data/pmtiles/full`**, upload files, add **`- /data/pmtiles/full`** to **`martin-config.yaml`**, restart Martin.
3. **Restart Martin** after adding files or changing config:  
   `docker-compose -f tileserver/docker-compose.tenant.yml restart martin`
4. **Avoid duplicate basenames** in two configured paths, or accept **`.1`** suffixes for duplicates and **never** point tenants at those ids.

### What was done on the VM during the session (examples)

- Uploaded **Delta** and **Abia** via **`gcp-upload-nigeria-state-pmtiles.sh`** when files were missing at the top level.
- Fixed **Martin** config after invalid **`/data/pmtiles/full`** entry; removed duplicate **`z6`** files when top-level copy existed.
- Confirmed **~21** `nigeria-*` entries in catalog — **not** full 37 until all files live under **discovered** paths.

---

## 8. File index (this session)

| Area | Files touched / added |
|------|-------------------------|
| Nginx | `tileserver/nginx-tenant-proxy.conf` |
| Lua | `resolve-tenant.lua`, `validate-tenant.lua`, `access-validate-and-origin.lua`, `tile-source-normalize.lua`, `admin-tenants.lua` |
| Martin | `tileserver/martin-config.yaml`, `martin-config-windows.yaml` |
| Scripts | `generate-states.sh`, `generate-states.ps1`, `deploy-gcp-lua.sh`, `deploy-gcp-view.sh`, `gcp-rename-boundaries-redeploy.sh`, `gcp-upload-nigeria-state-pmtiles.sh`, `flatten-pmtiles-for-martin.sh` |
| View | `config/urls.ts`, `lib/martinSources.ts`, `components/AddTenantWizard.vue` |
| Docs | `.github/copilot-instructions.md`, **this file** |

---

## 9. Quick reference commands (GCP)

```bash
# Upload one Nigerian state (from repo root, profile full)
./scripts/sh/gcp-upload-nigeria-state-pmtiles.sh abia

# Flatten local profile dirs into top-level data/ (then sync data/ to VM)
./scripts/sh/flatten-pmtiles-for-martin.sh

# Deploy Lua + nginx defaults
export GCP_REMOTE_BASE=/home/omarlakhdhar_gmail_com/rust-map-server  # if needed
./scripts/sh/deploy-gcp-lua.sh

# On VM after config/data changes
cd ~/rust-map-server/tileserver && sudo docker-compose -f docker-compose.tenant.yml restart martin nginx
```

---

*End of session notes — 2026-03-23.*
