// Empty string = relative URLs (production via vue-nginx.conf proxy).
// Set VITE_PROXY_URL=http://localhost:8080 for local dev without vite proxy.
export const DEFAULT_PROXY_URL = (import.meta.env.VITE_PROXY_URL as string) ?? '';
export const DEFAULT_MARTIN_URL = (import.meta.env.VITE_MARTIN_URL as string) || 'http://localhost:3000';

export function normalizeBaseUrl(url: string): string {
  return url.replace(/\/+$/, '');
}

