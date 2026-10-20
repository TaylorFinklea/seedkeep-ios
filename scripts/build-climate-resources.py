#!/usr/bin/env python3
"""Build the bundled ZIP climate table for the iOS app.

Reads the Seedkeep server's ZIP dataset (read-only) and writes
Seedkeep/Resources/Climate/zip_climate.csv with the columns zip,lat,lon,zone.
Frost dates are not stored per ZIP: the app derives them from the zone with
the 26-entry table in Seedkeep/Core/Climate/ZoneFrostDates.swift, which is
ported from the server's ZONE_FROST_FALLBACK. This script checks that every
zone maps to one frost pair in the source, which is the assumption that table
rests on.

Idempotent: the same source always produces the same bytes.

Usage:
    python3 -I scripts/build-climate-resources.py [path/to/zip_locations.csv]

The source defaults to ~/git/seedkeep-server/data/zip_locations.csv.
"""
import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = REPO_ROOT / "Seedkeep" / "Resources" / "Climate" / "zip_climate.csv"
DEFAULT_SOURCE = Path.home() / "git" / "seedkeep-server" / "data" / "zip_locations.csv"
SOURCE_COLUMNS = ["zip", "latitude", "longitude", "usda_zone", "avg_last_frost", "avg_first_frost"]
EXPECTED_ROWS = 33751


def fail(message):
    print(f"[build-climate-resources] ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def main(argv):
    source = Path(argv[1]) if len(argv) > 1 else DEFAULT_SOURCE
    if not source.is_file():
        fail(f"source not found: {source}")

    rows = []
    seen_zips = set()
    frost_by_zone = {}
    with source.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != SOURCE_COLUMNS:
            fail(f"unexpected columns: {reader.fieldnames}")
        for record in reader:
            zip_code = record["zip"]
            if len(zip_code) != 5 or not zip_code.isdigit():
                fail(f"malformed ZIP: {zip_code!r}")
            if zip_code in seen_zips:
                fail(f"duplicate ZIP: {zip_code}")
            seen_zips.add(zip_code)

            zone = record["usda_zone"]
            frost = (record["avg_last_frost"], record["avg_first_frost"])
            if frost_by_zone.setdefault(zone, frost) != frost:
                fail(f"zone {zone} has more than one frost pair")

            rows.append((zip_code, record["latitude"], record["longitude"], zone))

    if len(rows) != EXPECTED_ROWS:
        fail(f"expected {EXPECTED_ROWS} rows, found {len(rows)}")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("zip,lat,lon,zone\n")
        for zip_code, latitude, longitude, zone in rows:
            handle.write(f"{zip_code},{latitude},{longitude},{zone}\n")

    print(f"Wrote {len(rows)} rows to {OUTPUT} ({len(frost_by_zone)} zones)")


if __name__ == "__main__":
    main(sys.argv)
