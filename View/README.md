## Vue Tenant Viewer & Tile Inspector

This small Vue 3 + Vite app replaces the legacy HTML debug pages:

- `test-tenant-tiles.html`
- `tile-inspector.html`

It is intended for local debugging of the Rust tile server and Martin sources.

### Running locally

1. Open a terminal in the app directory:

   ```bash
   cd View
   pnpm install
   pnpm dev
   ```

2. Open the Vite dev URL shown in the terminal (by default `http://localhost:4000`).

### Views

- **Tenant Explorer** (`/tenant`): quick health check, catalog check, and tile loading tester per tenant, with live tile request logging.
- **Tile Inspector** (`/inspector`): richer map UI for exploring base and boundary layers, with HDX boundary tree navigation per tenant.

