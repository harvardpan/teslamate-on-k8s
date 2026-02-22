#!/usr/bin/env bash
set -euo pipefail

# TeslaMate on K8s — TeslaFi data import helper
# Usage: ./scripts/import-teslafi.sh [path-to-csv-directory]
#
# Copies TeslaFi CSV export files into the TeslaMate pod for import.
# CSV files must be named TeslaFi<M><YYYY>.csv or TeslaFi<MM><YYYY>.csv
# where M/MM is month (1-12) and YYYY is year (2000-2200).
#
# Default import directory: ./import/ (repo root)

NAMESPACE="teslamate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMPORT_DIR="${1:-${REPO_ROOT}/import}"

echo "=== TeslaFi Data Import ==="
echo ""

if [ ! -d "$IMPORT_DIR" ]; then
  echo "Error: Import directory not found: ${IMPORT_DIR}"
  echo ""
  echo "Create the directory and place your TeslaFi CSV exports there:"
  echo "  mkdir -p ${REPO_ROOT}/import"
  echo ""
  echo "To export from TeslaFi:"
  echo "  1. Log in to https://teslafi.com"
  echo "  2. Go to Settings > Account > Advanced > Download TeslaFi Data"
  echo "     (or visit https://teslafi.com/export2.php directly)"
  echo "  3. Select a month and year, then click Submit to download"
  echo "  4. Repeat for each month you want to import"
  echo "  5. Place the downloaded CSV files in: ${REPO_ROOT}/import/"
  exit 1
fi

# Find TeslaFi CSV files
CSV_FILES=$(find "$IMPORT_DIR" -maxdepth 1 -name 'TeslaFi*.csv' 2>/dev/null | sort)
if [ -z "$CSV_FILES" ]; then
  echo "Error: No TeslaFi*.csv files found in ${IMPORT_DIR}"
  echo ""
  echo "To export from TeslaFi:"
  echo "  1. Log in to https://teslafi.com"
  echo "  2. Go to Settings > Account > Advanced > Download TeslaFi Data"
  echo "     (or visit https://teslafi.com/export2.php directly)"
  echo "  3. Select a month and year, then click Submit to download"
  echo "  4. Repeat for each month you want to import"
  echo "  5. Place the downloaded CSV files in: ${IMPORT_DIR}/"
  echo ""
  echo "Files must be named TeslaFi<month><year>.csv (e.g. TeslaFi92022.csv)"
  exit 1
fi

# Validate filenames match TeslaFi<M or MM><YYYY>.csv pattern
INVALID_FILES=()
VALID_FILES=()
while read -r f; do
  basename=$(basename "$f")
  # Strip prefix and suffix to get the month+year portion
  middle="${basename#TeslaFi}"
  middle="${middle%.csv}"

  valid=true
  # Must be 5 or 6 characters (1-digit or 2-digit month + 4-digit year)
  if [[ ${#middle} -lt 5 || ${#middle} -gt 6 ]]; then
    valid=false
  else
    # Extract year (always last 4 chars) and month (remaining prefix)
    year="${middle: -4}"
    month="${middle:0:${#middle}-4}"

    # Month must be 1-12 (no leading zeros)
    if ! [[ "$month" =~ ^[1-9][0-2]?$ ]]; then
      valid=false
    elif [[ "$month" -lt 1 || "$month" -gt 12 ]]; then
      valid=false
    fi

    # Year must be 2000-2200
    if ! [[ "$year" =~ ^[0-9]{4}$ ]]; then
      valid=false
    elif [[ "$year" -lt 2000 || "$year" -gt 2200 ]]; then
      valid=false
    fi
  fi

  if [ "$valid" = true ]; then
    VALID_FILES+=("$f")
  else
    INVALID_FILES+=("$basename")
  fi
done <<< "$CSV_FILES"

if [ ${#INVALID_FILES[@]} -gt 0 ]; then
  echo "Error: Invalid TeslaFi filename(s):"
  for f in "${INVALID_FILES[@]}"; do
    echo "  $f"
  done
  echo ""
  echo "Expected format: TeslaFi<month><year>.csv"
  echo "  Month: 1-12 (no leading zero)"
  echo "  Year:  2000-2200"
  echo "  Examples: TeslaFi92022.csv (September 2022)"
  echo "            TeslaFi122023.csv (December 2023)"
  exit 1
fi

echo "Found ${#VALID_FILES[@]} CSV file(s) in ${IMPORT_DIR}:"
for f in "${VALID_FILES[@]}"; do
  echo "  $(basename "$f")"
done
echo ""

# Fix known TeslaFi export issue (github.com/teslamate-org/teslamate/issues/4477):
# Several columns may be exported as decimals but TeslaMate requires integers.
# Affected columns (1-indexed): 25=charger_power, 30=charger_actual_current,
# 37=battery_level, 51=charger_voltage.
echo "Fixing decimal values in CSV columns..."
FIXED_COUNT=0
for f in "${VALID_FILES[@]}"; do
  before=$(perl -F, -lane '
    print if $F[24] =~ /-?\d+\.\d+/ || $F[29] =~ /-?\d+\.\d+/ ||
            $F[36] =~ /-?\d+\.\d+/ || $F[50] =~ /-?\d+\.\d+/
  ' "$f" | wc -l)
  if [ "$before" -gt 0 ]; then
    perl -i -F, -lane '
      if ($. > 1) {
        for my $i (24, 29, 36, 50) {
          if ($F[$i] =~ /^-?\d+\.\d+$/) {
            $F[$i] = int($F[$i] + ($F[$i] >= 0 ? 0.5 : -0.5));
          }
        }
      }
      print join(",", @F);
    ' "$f"
    echo "  Fixed $(basename "$f"): $before rows"
    FIXED_COUNT=$((FIXED_COUNT + before))
  fi
done
if [ "$FIXED_COUNT" -gt 0 ]; then
  echo "  Total: ${FIXED_COUNT} rows with decimal values fixed"
else
  echo "  No decimal values found (all clean)"
fi
echo ""

# Fix usable_battery_level (column 33, 1-indexed / 32, 0-indexed).
# The Tesla API sometimes returns a frozen/stale value that doesn't track actual
# charge level (e.g., stuck at 63 while battery_level ranges 18-100). This causes
# TeslaMate to calculate wildly incorrect battery capacity (~136 kWh instead of
# ~82 kWh). The Battery Health dashboard uses usable_battery_level as a divisor,
# so NULL values break it entirely.
# Fix: fill empty values with battery_level, and replace stale values where
# usable_battery_level > battery_level (physically impossible).
echo "Fixing usable_battery_level..."
UBL_FIXED=0
for f in "${VALID_FILES[@]}"; do
  count=$(perl -F, -lane '
    if ($. > 1) {
      my $ubl = $F[32];
      my $bl = $F[36];
      # Count rows where usable_battery_level is empty or stale (> battery_level)
      if ($bl =~ /^\d+$/) {
        print if $ubl !~ /^\d+$/ || $ubl > $bl;
      }
    }
  ' "$f" | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    perl -i -F, -lane '
      if ($. > 1) {
        my $ubl = $F[32];
        my $bl = $F[36];
        if ($bl =~ /^\d+$/) {
          if ($ubl !~ /^\d+$/ || $ubl > $bl) {
            $F[32] = $bl;
          }
        }
      }
      print join(",", @F);
    ' "$f"
    echo "  Fixed $(basename "$f"): $count rows"
    UBL_FIXED=$((UBL_FIXED + count))
  fi
done
if [ "$UBL_FIXED" -gt 0 ]; then
  echo "  Total: ${UBL_FIXED} rows with usable_battery_level fixed"
else
  echo "  No usable_battery_level issues found"
fi
echo ""

# Get the TeslaMate pod name
POD=$(kubectl get pod -n "$NAMESPACE" -l app=teslamate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "Error: No TeslaMate pod found in namespace ${NAMESPACE}"
  echo "Make sure TeslaMate is deployed: make tilt-up"
  exit 1
fi
echo "TeslaMate pod: ${POD}"
echo ""

# Copy files to the pod
echo "Copying CSV files to pod..."
for f in "${VALID_FILES[@]}"; do
  echo "  Copying $(basename "$f")..."
  kubectl cp "$f" "${POD}:/opt/app/import/$(basename "$f")" -n "$NAMESPACE"
done

echo ""
echo "=== Files copied successfully ==="
echo ""
echo "TeslaMate must be restarted to detect the import files."
echo ""
read -p "Restart TeslaMate now? (Y/n): " RESTART
if [ "$RESTART" != "n" ] && [ "$RESTART" != "N" ]; then
  echo "Restarting TeslaMate..."
  kubectl rollout restart deploy/teslamate -n "$NAMESPACE"
  kubectl rollout status deploy/teslamate -n "$NAMESPACE" --timeout=60s
  echo ""
  echo "TeslaMate restarted in import mode."
  echo ""
  echo "Next steps:"
  echo "  1. Open TeslaMate (http://localhost:4000 or your configured hostname)"
  echo "     You will be redirected to the import page automatically."
  echo "  2. Select your local timezone and start the import."
  echo "  3. After import completes, clean up with:"
  echo "       kubectl exec -n $NAMESPACE deploy/teslamate -- rm /opt/app/import/TeslaFi*.csv"
  echo "       kubectl rollout restart deploy/teslamate -n $NAMESPACE"
else
  echo ""
  echo "Skipped restart. When you're ready, restart manually:"
  echo "  kubectl rollout restart deploy/teslamate -n $NAMESPACE"
  echo ""
  echo "After restart, TeslaMate will enter import mode automatically."
  echo "Open the UI and you will be redirected to the import page."
  echo ""
  echo "After import completes, clean up with:"
  echo "  kubectl exec -n $NAMESPACE deploy/teslamate -- rm /opt/app/import/TeslaFi*.csv"
  echo "  kubectl rollout restart deploy/teslamate -n $NAMESPACE"
fi
echo ""
echo "Note: Import is a BETA feature. Only data prior to your first"
echo "TeslaMate entry will be imported (no overlap)."
