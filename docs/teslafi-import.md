# TeslaFi Data Import

Import your historical TeslaFi data into TeslaMate.

## Export from TeslaFi

1. Log in to [TeslaFi](https://www.teslafi.com/)
2. Go to **Settings > Account > Advanced > Download TeslaFi Data**
   (or navigate directly to [teslafi.com/export2.php](https://teslafi.com/export2.php))
3. Select a **month** and **year** from the dropdowns, then click **Submit** to download
4. Repeat for each month you want to import
5. Place the downloaded CSV files in the `import/` directory at the repo root

Files are named `TeslaFi<month><year>.csv` by TeslaFi (e.g., `TeslaFi92022.csv` for September 2022).

## Import into TeslaMate

### Using the helper script (recommended)

```bash
# Place CSV files in ./import/ then run:
make import-teslafi

# Or specify a custom directory:
make import-teslafi CSV_DIR=/path/to/csv/files/
```

The script will:
1. Validate the filenames
2. Fix known decimal-to-integer data issues (see [Data fixes](#data-fixes) below)
3. Copy the CSV files into the TeslaMate pod
4. Ask if you want to restart TeslaMate to enter import mode
5. After restart, TeslaMate auto-redirects to the import page

### Manual import

```bash
# Get the TeslaMate pod name
POD=$(kubectl get pod -n teslamate -l app=teslamate -o jsonpath='{.items[0].metadata.name}')

# Copy CSV files to the pod
kubectl cp TeslaFi*.csv ${POD}:/opt/app/import/ -n teslamate

# Restart TeslaMate to detect the files
kubectl rollout restart deploy/teslamate -n teslamate
```

Then open the TeslaMate web UI — it will redirect to the import page automatically.

## After import

Once the import is complete, remove the CSV files and restart to return to normal mode:

```bash
kubectl exec -n teslamate deploy/teslamate -- sh -c 'rm /opt/app/import/TeslaFi*.csv'
kubectl rollout restart deploy/teslamate -n teslamate
```

## Data fixes

TeslaFi exports since late 2024 contain decimal values in columns that TeslaMate expects as
integers, causing the import to fail or skip charge data
([teslamate-org/teslamate#4477](https://github.com/teslamate-org/teslamate/issues/4477)).

The `make import-teslafi` script automatically fixes these columns before copying files to the pod:

| Column (1-indexed) | Field | Example bad value |
|---|---|---|
| 25 | `charger_power` | `-0.0517112` |
| 30 | `charger_actual_current` | `48.0` |
| 33 | `usable_battery_level` | `62.5` |
| 37 | `battery_level` | `48.45` |
| 51 | `charger_voltage` | `4.0` |

Values are rounded to the nearest integer. If you are importing manually (without the script),
you must fix these columns yourself or the import will either crash or silently drop charge data.

## Notes

- The import feature is **BETA**
- TeslaMate must be **restarted** after CSV files are placed in the pod — it only checks for import files at startup
- Only data **prior to your first TeslaMate entry** is imported (no overlap)
- If the import is interrupted (e.g., OOM kill), TeslaMate may consider it "complete" on retry — you must delete the partially imported data from the database and restart (see [TeslaMate import docs](https://docs.teslamate.org/docs/import/teslafi/))
- Addresses are auto-populated during/after import (repair phase runs in the background)
- For multi-vehicle setups, set the `TESLAFI_IMPORT_VEHICLE_ID` environment variable (defaults to `1`)
