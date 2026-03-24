// Empty string = relative URLs (production via vue-nginx.conf proxy).
// Set VITE_PROXY_URL=http://localhost:8080 for local dev without vite proxy.
export const DEFAULT_PROXY_URL = (import.meta.env.VITE_PROXY_URL as string) ?? '';

function inferMartinBaseUrl(): string {
  const explicit = (import.meta.env.VITE_MARTIN_URL as string) || '';
  if (explicit) return explicit;
  const proxy = (import.meta.env.VITE_PROXY_URL as string) || '';
  if (proxy) {
    try {
      const u = new URL(proxy);
      u.port = '3000';
      return u.toString().replace(/\/+$/, '');
    } catch {
      /* ignore */
    }
  }
  return 'http://localhost:3000';
}

/** Martin HTTP root (tile JSON + raster). If VITE_MARTIN_URL unset, uses same host as VITE_PROXY_URL with port 3000. */
export const DEFAULT_MARTIN_URL = inferMartinBaseUrl();

export function normalizeBaseUrl(url: string): string {
  return url.replace(/\/+$/, '');
}

