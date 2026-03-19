// admin-level-labels.js
// Authoritative admin level type labels per country, per OCHA COD-AB standard.
//
// Source: OCHA Field Information Services (FIS) COD-AB metadata registry
//   https://data.humdata.org/dashboards/cod
//
// Used by all import scripts to set adm_features.level_label consistently.
// Keys are ISO 3166-1 alpha-2 country codes; values map adm_level -> label.
//
// Notes:
//   - NG adm3 from HDX = Ward (NE partial coverage: Borno/Adamawa/Yobe)
//     INEC electoral data (Senatorial District, FC) sets its own label on insert
//     and is never NULL, so this table does not affect those rows.
//   - IN adm3 is "Mandal" in Andhra Pradesh and "Sub-District" in Manipur;
//     "Sub-District" is used here as the generic OCHA term for India.
//   - CF uses French official names (Préfecture / Sous-préfecture).

'use strict';

const ADM_LEVEL_LABELS = {
  NG: {
    1: 'State',
    2: 'Local Government Area',
    3: 'Ward',
  },
  KE: {
    1: 'County',
    2: 'Sub-County',
    3: 'Ward',
  },
  UG: {
    1: 'Region',
    2: 'District',
    3: 'County',
    4: 'Sub-County',
    5: 'Parish',
  },
  RW: {
    1: 'Province',
    2: 'District',
    3: 'Sector',
    4: 'Cell',
    5: 'Village',
  },
  LR: {
    1: 'County',
    2: 'District',
    3: 'Clan',
  },
  CF: {
    1: 'Préfecture',
    2: 'Sous-préfecture',
    3: 'Commune',
  },
  IN: {
    1: 'State',
    2: 'District',
    3: 'Sub-District',
  },
};

/**
 * Look up the label for a given country + adm level.
 * Returns null if not found (caller can skip or use a fallback).
 *
 * @param {string} countryCode  ISO2 code, e.g. 'NG'
 * @param {number} admLevel     Admin level integer, e.g. 2
 * @returns {string|null}
 */
function getLabel(countryCode, admLevel) {
  const country = ADM_LEVEL_LABELS[countryCode];
  if (!country) return null;
  return country[admLevel] || null;
}

module.exports = { ADM_LEVEL_LABELS, getLabel };
