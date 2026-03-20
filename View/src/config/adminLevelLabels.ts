/**
 * Admin-level display names by ISO country code.
 * Kept in sync with scripts/admin-level-labels.js (OCHA COD-AB terminology).
 */
const ADM_LEVEL_LABELS: Record<string, Record<number, string>> = {
  NG: { 1: 'State', 2: 'Local Government Area', 3: 'Ward' },
  KE: { 1: 'County', 2: 'Sub-County', 3: 'Ward' },
  UG: { 1: 'Region', 2: 'District', 3: 'County', 4: 'Sub-County', 5: 'Parish' },
  RW: { 1: 'Province', 2: 'District', 3: 'Sector', 4: 'Cell', 5: 'Village' },
  LR: { 1: 'County', 2: 'District', 3: 'Clan' },
  CF: { 1: 'Préfecture', 2: 'Sous-préfecture', 3: 'Commune' },
  IN: { 1: 'State', 2: 'District', 3: 'Sub-District' },
};

export function adminLevelLabel(countryCode: string, admLevel: number): string | null {
  const row = ADM_LEVEL_LABELS[countryCode.toUpperCase()] ?? null;
  if (!row) return null;
  return row[admLevel] ?? null;
}
