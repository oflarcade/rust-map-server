#!/usr/bin/env python3
"""
filter-gadm.py - Filter GADM GeoJSON data by state names
Outputs filtered GeoJSON files and bounding box info for each state.

Usage:
    python3 filter-gadm.py <gadm_level2_file> <output_dir> <state1> <state2> ...

Example:
    python3 filter-gadm.py gadm/nigeria_2.json gadm/states Lagos Edo Bayelsa Jigawa
"""

import json
import os
import sys


def compute_bounds(features):
    """Compute the bounding box of a list of GeoJSON features."""
    min_lon, min_lat = float('inf'), float('inf')
    max_lon, max_lat = float('-inf'), float('-inf')

    def walk_coords(coords):
        nonlocal min_lon, min_lat, max_lon, max_lat
        if isinstance(coords[0], (int, float)):
            min_lon = min(min_lon, coords[0])
            min_lat = min(min_lat, coords[1])
            max_lon = max(max_lon, coords[0])
            max_lat = max(max_lat, coords[1])
        else:
            for c in coords:
                walk_coords(c)

    for f in features:
        walk_coords(f['geometry']['coordinates'])

    return min_lon, min_lat, max_lon, max_lat


def main():
    if len(sys.argv) < 4:
        print("Usage: filter-gadm.py <gadm_level2_file> <output_dir> <state1> [state2] ...")
        sys.exit(1)

    gadm_file = sys.argv[1]
    output_dir = sys.argv[2]
    target_states = sys.argv[3:]

    os.makedirs(output_dir, exist_ok=True)

    with open(gadm_file) as f:
        data = json.load(f)

    # Get all available state names for error checking
    all_states = sorted(set(feat['properties']['NAME_1'] for feat in data['features']))

    # Validate requested states
    for state in target_states:
        if state not in all_states:
            print(f"ERROR: State '{state}' not found in GADM data.", file=sys.stderr)
            print(f"Available states:", file=sys.stderr)
            for s in all_states:
                print(f"  - {s}", file=sys.stderr)
            sys.exit(1)

    bounds_info = {}

    for state in target_states:
        features = [f for f in data['features'] if f['properties']['NAME_1'] == state]
        min_lon, min_lat, max_lon, max_lat = compute_bounds(features)

        # Add a small buffer (~1km) to avoid edge clipping
        buffer = 0.01
        min_lon -= buffer
        min_lat -= buffer
        max_lon += buffer
        max_lat += buffer

        # Create state slug for filenames
        slug = state.lower().replace(' ', '-')

        # Write filtered GeoJSON
        filtered = {
            "type": "FeatureCollection",
            "features": features
        }
        out_path = os.path.join(output_dir, f"{slug}.json")
        with open(out_path, 'w') as f:
            json.dump(filtered, f)

        bounds_info[slug] = {
            "name": state,
            "slug": slug,
            "feature_count": len(features),
            "bounds": f"{min_lon:.6f},{min_lat:.6f},{max_lon:.6f},{max_lat:.6f}",
            "min_lon": min_lon,
            "min_lat": min_lat,
            "max_lon": max_lon,
            "max_lat": max_lat,
            "center_lon": (min_lon + max_lon) / 2,
            "center_lat": (min_lat + max_lat) / 2,
        }

        print(f"  {state}: {len(features)} features -> {out_path}")
        print(f"    bounds: {min_lon:.4f},{min_lat:.4f},{max_lon:.4f},{max_lat:.4f}")

    # Also write combined GeoJSON (all states in one file)
    combined_features = [f for f in data['features'] if f['properties']['NAME_1'] in target_states]
    combined = {"type": "FeatureCollection", "features": combined_features}
    combined_path = os.path.join(output_dir, "combined.json")
    with open(combined_path, 'w') as f:
        json.dump(combined, f)
    print(f"  Combined: {len(combined_features)} features -> {combined_path}")

    # Write bounds info as JSON (for the shell script to read)
    bounds_path = os.path.join(output_dir, "bounds.json")
    with open(bounds_path, 'w') as f:
        json.dump(bounds_info, f, indent=2)
    print(f"  Bounds info -> {bounds_path}")


if __name__ == '__main__':
    main()
