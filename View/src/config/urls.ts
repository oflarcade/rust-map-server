export const DEFAULT_PROXY_URL = 'http://localhost:8080';
export const DEFAULT_MARTIN_URL = 'http://localhost:3000';

export function normalizeBaseUrl(url: string): string {
  return url.replace(/\/+$/, '');
}

