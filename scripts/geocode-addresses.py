#!/usr/bin/env python3
"""
TeslaMate on K8s — Smart address geocoding script.

Geocodes pending addresses in the TeslaMate database using the Google Maps
Geocoding API. Uses ~50m coordinate clustering to minimize API calls:
- Groups nearby coordinates into grid cells
- Reuses existing addresses when a geocoded address is already nearby
- Makes ONE API call per unique location cluster
- Assigns the result to ALL records in that cluster

Usage:
    ./scripts/geocode-addresses.py [options]

Requirements:
    pip install psycopg2-binary
"""

import argparse
import json
import math
import os
import sys
import time
import urllib.request
import urllib.error

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("Error: psycopg2 is required. Install with:")
    print("  pip install psycopg2-binary")
    sys.exit(1)

# Grid size for coordinate clustering (in degrees)
# 0.0005° ≈ 55m latitude, ~41m longitude at 42°N
DEFAULT_GRID_SIZE = 0.0005


def snap_to_grid(lat, lng, grid_size):
    """Snap coordinates to the nearest grid cell."""
    return (
        round(float(lat) / grid_size) * grid_size,
        round(float(lng) / grid_size) * grid_size,
    )


def reverse_geocode_google(lat, lng, api_key):
    """Call Google Maps Reverse Geocoding API."""
    url = (
        f"https://maps.googleapis.com/maps/api/geocode/json"
        f"?latlng={lat},{lng}&key={api_key}"
    )
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        print(f"  HTTP {e.code}: {body[:200]}")
        return None
    except urllib.error.URLError as e:
        print(f"  URL error: {e.reason}")
        return None

    if data.get("status") != "OK" or not data.get("results"):
        print(f"  API status: {data.get('status')} — {data.get('error_message', '')}")
        return None

    return data["results"][0]


def extract_component(result, component_type):
    """Extract a specific address component from a Google Maps result."""
    for comp in result.get("address_components", []):
        if component_type in comp.get("types", []):
            return comp.get("long_name")
    return None


def google_result_to_address(result, grid_lat, grid_lng):
    """Convert a Google Maps geocoding result to a TeslaMate address dict."""
    return {
        "display_name": result.get("formatted_address", ""),
        "latitude": round(grid_lat, 6),
        "longitude": round(grid_lng, 6),
        "name": extract_component(result, "point_of_interest")
        or extract_component(result, "premise")
        or extract_component(result, "route"),
        "house_number": extract_component(result, "street_number"),
        "road": extract_component(result, "route"),
        "neighbourhood": (
            extract_component(result, "neighborhood")
            or extract_component(result, "sublocality")
        ),
        "city": (
            extract_component(result, "locality")
            or extract_component(result, "sublocality_level_1")
        ),
        "county": extract_component(result, "administrative_area_level_2"),
        "postcode": extract_component(result, "postal_code"),
        "state": extract_component(result, "administrative_area_level_1"),
        "state_district": extract_component(result, "administrative_area_level_3"),
        "country": extract_component(result, "country"),
        "raw": json.dumps(result),
    }


def insert_address(cur, addr):
    """Insert a new address into the addresses table, return its ID."""
    cur.execute(
        """
        INSERT INTO addresses (
            display_name, latitude, longitude, name, house_number, road,
            neighbourhood, city, county, postcode, state, state_district,
            country, raw, inserted_at, updated_at, osm_id, osm_type
        ) VALUES (
            %(display_name)s, %(latitude)s, %(longitude)s, %(name)s,
            %(house_number)s, %(road)s, %(neighbourhood)s, %(city)s,
            %(county)s, %(postcode)s, %(state)s, %(state_district)s,
            %(country)s, %(raw)s, NOW(), NOW(), NULL, NULL
        )
        RETURNING id
        """,
        addr,
    )
    return cur.fetchone()[0]


def find_placeholder_id(cur):
    """Find the placeholder address ID."""
    cur.execute(
        "SELECT id FROM addresses WHERE display_name LIKE '%Pending Geocode%' LIMIT 1"
    )
    row = cur.fetchone()
    return row[0] if row else None


def get_pending_records(cur, placeholder_id):
    """Get all records that need geocoding, grouped by type."""
    records = []

    # Drive start addresses
    cur.execute(
        """
        SELECT d.id, 'drive_start' AS type, p.latitude, p.longitude
        FROM drives d
        JOIN positions p ON d.start_position_id = p.id
        WHERE d.start_address_id = %s
        """,
        (placeholder_id,),
    )
    records.extend(cur.fetchall())

    # Drive end addresses
    cur.execute(
        """
        SELECT d.id, 'drive_end' AS type, p.latitude, p.longitude
        FROM drives d
        JOIN positions p ON d.end_position_id = p.id
        WHERE d.end_address_id = %s
        """,
        (placeholder_id,),
    )
    records.extend(cur.fetchall())

    # Charging process addresses
    cur.execute(
        """
        SELECT c.id, 'charging' AS type, p.latitude, p.longitude
        FROM charging_processes c
        JOIN positions p ON c.position_id = p.id
        WHERE c.address_id = %s
        """,
        (placeholder_id,),
    )
    records.extend(cur.fetchall())

    return records


def get_existing_addresses(cur, placeholder_id):
    """Get all existing non-placeholder addresses with their grid cells."""
    cur.execute(
        """
        SELECT id, latitude, longitude
        FROM addresses
        WHERE id != %s AND latitude IS NOT NULL AND longitude IS NOT NULL
        """,
        (placeholder_id,),
    )
    return cur.fetchall()


def build_existing_grid(existing_addresses, grid_size):
    """Build a mapping of grid cells to existing address IDs."""
    grid = {}
    for addr_id, lat, lng in existing_addresses:
        cell = snap_to_grid(lat, lng, grid_size)
        # Keep the first address found per cell (typically the one TeslaMate created)
        if cell not in grid:
            grid[cell] = addr_id
    return grid


def update_records(cur, record_type, record_id, address_id):
    """Update a drive or charging process with the resolved address ID."""
    if record_type == "drive_start":
        cur.execute(
            "UPDATE drives SET start_address_id = %s WHERE id = %s",
            (address_id, record_id),
        )
    elif record_type == "drive_end":
        cur.execute(
            "UPDATE drives SET end_address_id = %s WHERE id = %s",
            (address_id, record_id),
        )
    elif record_type == "charging":
        cur.execute(
            "UPDATE charging_processes SET address_id = %s WHERE id = %s",
            (address_id, record_id),
        )


def main():
    parser = argparse.ArgumentParser(
        description="Smart geocoding for TeslaMate addresses"
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("GOOGLE_MAPS_API_KEY"),
        help="Google Maps API key (or set GOOGLE_MAPS_API_KEY env var)",
    )
    parser.add_argument(
        "--db-host", default="127.0.0.1", help="PostgreSQL host (default: 127.0.0.1)"
    )
    parser.add_argument(
        "--db-port", type=int, default=5432, help="PostgreSQL port (default: 5432)"
    )
    parser.add_argument(
        "--db-user", default="teslamate", help="PostgreSQL user (default: teslamate)"
    )
    parser.add_argument(
        "--db-pass",
        default=os.environ.get("DATABASE_PASS"),
        help="PostgreSQL password (or set DATABASE_PASS env var)",
    )
    parser.add_argument(
        "--db-name",
        default="teslamate",
        help="PostgreSQL database (default: teslamate)",
    )
    parser.add_argument(
        "--grid-size",
        type=float,
        default=DEFAULT_GRID_SIZE,
        help=f"Grid size in degrees (default: {DEFAULT_GRID_SIZE} ≈ 50m)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview what would happen without making changes",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.1,
        help="Delay between API calls in seconds (default: 0.1)",
    )
    args = parser.parse_args()

    if not args.api_key and not args.dry_run:
        print("Error: Google Maps API key required.")
        print("  Set GOOGLE_MAPS_API_KEY env var or use --api-key")
        sys.exit(1)

    if not args.db_pass:
        print("Error: Database password required.")
        print("  Set DATABASE_PASS env var or use --db-pass")
        sys.exit(1)

    grid_meters_lat = args.grid_size * 111_000
    grid_meters_lng = args.grid_size * 111_000 * math.cos(math.radians(42))
    print(f"=== TeslaMate Smart Geocoding ===")
    print(f"Grid size: {args.grid_size}° ≈ {grid_meters_lat:.0f}m lat × {grid_meters_lng:.0f}m lng")
    if args.dry_run:
        print("Mode: DRY RUN (no changes will be made)")
    print()

    # Connect to database
    print("Connecting to PostgreSQL...")
    conn = psycopg2.connect(
        host=args.db_host,
        port=args.db_port,
        user=args.db_user,
        password=args.db_pass,
        dbname=args.db_name,
    )
    conn.autocommit = False
    cur = conn.cursor()
    print("  Connected.")
    print()

    # Find placeholder address
    placeholder_id = find_placeholder_id(cur)
    if not placeholder_id:
        print("No placeholder addresses found. Nothing to geocode.")
        cur.close()
        conn.close()
        return

    print(f"Placeholder address ID: {placeholder_id}")

    # Get pending records
    pending = get_pending_records(cur, placeholder_id)
    if not pending:
        print("No pending records found. Everything is already geocoded.")
        cur.close()
        conn.close()
        return

    drive_starts = sum(1 for _, t, _, _ in pending if t == "drive_start")
    drive_ends = sum(1 for _, t, _, _ in pending if t == "drive_end")
    charging = sum(1 for _, t, _, _ in pending if t == "charging")
    print(f"Pending records: {len(pending)} total")
    print(f"  Drive starts: {drive_starts}")
    print(f"  Drive ends:   {drive_ends}")
    print(f"  Charging:     {charging}")
    print()

    # Build grid clusters from pending records
    clusters = {}  # grid_cell -> [(record_id, record_type, lat, lng), ...]
    for record_id, record_type, lat, lng in pending:
        cell = snap_to_grid(lat, lng, args.grid_size)
        if cell not in clusters:
            clusters[cell] = []
        clusters[cell].append((record_id, record_type, lat, lng))

    print(f"Unique location clusters (~{grid_meters_lat:.0f}m): {len(clusters)}")
    print()

    # Get existing addresses and build grid
    existing = get_existing_addresses(cur, placeholder_id)
    existing_grid = build_existing_grid(existing, args.grid_size)
    print(f"Existing geocoded addresses: {len(existing)}")
    print()

    # Phase 1: Match existing addresses
    print("=== Phase 1: Matching existing addresses ===")
    matched_from_existing = 0
    records_updated_phase1 = 0

    cells_to_geocode = {}
    for cell, records in clusters.items():
        if cell in existing_grid:
            addr_id = existing_grid[cell]
            matched_from_existing += 1
            if not args.dry_run:
                for record_id, record_type, _, _ in records:
                    update_records(cur, record_type, record_id, addr_id)
            records_updated_phase1 += len(records)
        else:
            cells_to_geocode[cell] = records

    print(f"  Matched {matched_from_existing} locations to existing addresses")
    print(f"  Updated {records_updated_phase1} records (0 API calls)")
    print(f"  Remaining: {len(cells_to_geocode)} locations need geocoding")
    print()

    if not args.dry_run:
        conn.commit()

    # Phase 2: Geocode remaining locations
    print("=== Phase 2: Geocoding new locations ===")
    if args.dry_run:
        print(f"  Would make {len(cells_to_geocode)} Google Maps API calls")
        print(f"  Would update {sum(len(r) for r in cells_to_geocode.values())} records")
        print()
    else:
        if not args.api_key:
            print("Error: API key required for Phase 2 (not a dry run)")
            cur.close()
            conn.close()
            sys.exit(1)

        api_calls = 0
        api_errors = 0
        records_updated_phase2 = 0
        total_cells = len(cells_to_geocode)

        for i, (cell, records) in enumerate(cells_to_geocode.items(), 1):
            grid_lat, grid_lng = cell
            pct = i / total_cells * 100

            # Pick a representative coordinate (first record's actual position)
            _, _, actual_lat, actual_lng = records[0]

            sys.stdout.write(
                f"\r  [{i}/{total_cells}] ({pct:.0f}%) Geocoding ({float(actual_lat):.4f}, {float(actual_lng):.4f})..."
            )
            sys.stdout.flush()

            result = reverse_geocode_google(
                float(actual_lat), float(actual_lng), args.api_key
            )
            api_calls += 1

            if result:
                addr = google_result_to_address(result, grid_lat, grid_lng)
                addr_id = insert_address(cur, addr)

                for record_id, record_type, _, _ in records:
                    update_records(cur, record_type, record_id, addr_id)
                records_updated_phase2 += len(records)

                # Commit every 50 addresses to avoid losing progress
                if api_calls % 50 == 0:
                    conn.commit()
            else:
                api_errors += 1

            if args.delay > 0:
                time.sleep(args.delay)

        conn.commit()
        print()
        print(f"  API calls: {api_calls} ({api_errors} errors)")
        print(f"  Records updated: {records_updated_phase2}")
        print()

    # Phase 3: Cleanup & Report
    print("=== Phase 3: Summary ===")

    if not args.dry_run:
        # Check if placeholder is still referenced
        cur.execute(
            """
            SELECT COUNT(*) FROM (
                SELECT 1 FROM drives WHERE start_address_id = %s
                UNION ALL SELECT 1 FROM drives WHERE end_address_id = %s
                UNION ALL SELECT 1 FROM charging_processes WHERE address_id = %s
            ) refs
            """,
            (placeholder_id, placeholder_id, placeholder_id),
        )
        remaining = cur.fetchone()[0]

        if remaining == 0:
            print(f"  Deleting placeholder address (ID {placeholder_id})...")
            cur.execute("DELETE FROM addresses WHERE id = %s", (placeholder_id,))
            conn.commit()
            print("  Placeholder removed.")
        else:
            print(f"  {remaining} records still reference placeholder (errors during geocoding)")

    total_records = len(pending)
    print()
    print(f"  Total records processed: {total_records}")
    print(f"  Resolved from existing: {records_updated_phase1} ({matched_from_existing} locations)")
    if not args.dry_run:
        print(f"  Geocoded via API:       {records_updated_phase2} ({api_calls} API calls)")
        if api_errors:
            print(f"  Errors:                 {api_errors} locations failed")
        est_cost = api_calls * 0.005 if api_calls > 10000 else 0
        print(f"  Estimated cost:         ${est_cost:.2f} (free tier: 10,000/month)")
    else:
        need_api = sum(len(r) for r in cells_to_geocode.values())
        print(f"  Would geocode via API:  {need_api} records ({len(cells_to_geocode)} API calls)")
        est_cost = len(cells_to_geocode) * 0.005 if len(cells_to_geocode) > 10000 else 0
        print(f"  Estimated cost:         ${est_cost:.2f} (free tier: 10,000/month)")

    print()
    print("=== Done ===")

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
