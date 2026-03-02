#!/bin/bash
set -euo pipefail

# =============================================================================
# cleanup.sh — Clean up artefacts on an existing server before upgrading to v4
#
# Run this ONCE on your existing TrueNAS server before deploying v4.
# It removes known rogue files/directories from earlier iterations.
#
# Usage:
#   chmod +x cleanup.sh
#   ./cleanup.sh          # dry-run (shows what would be deleted)
#   ./cleanup.sh --apply  # actually delete
# =============================================================================

BASE="/mnt/sharedrive/apps/hummingbot"
DRY_RUN=true

if [ "${1:-}" = "--apply" ]; then
  DRY_RUN=false
fi

echo "============================================"
echo "  Trading Pod — Cleanup"
if $DRY_RUN; then
  echo "  MODE: DRY RUN (pass --apply to execute)"
else
  echo "  MODE: APPLYING CHANGES"
fi
echo "============================================"
echo ""

remove_item() {
  path="$1"
  reason="$2"
  if [ -e "$path" ]; then
    echo "  REMOVE: $path"
    echo "          Reason: $reason"
    if ! $DRY_RUN; then
      rm -rf "$path"
      echo "          → Deleted."
    fi
  fi
}

echo "--- Rogue Docker bind-mount artefacts ---"
remove_item "$BASE/api/docker_service.py" \
  "Directory created by Docker when file mount target was missing. Not used by compose."

echo ""
echo "--- Nested duplicate directory ---"
remove_item "$BASE/api/data/data" \
  "Double-nested 'data' directory from an earlier bug. Empty duplicate structure."

echo ""
echo "--- Deprecated scripts ---"
remove_item "$BASE/bootstrap/emqx-seed.sh" \
  "Old seed script (with hyphen). Replaced by hummingbot_seed.sh."

echo ""
echo "--- Leftover backups ---"
remove_item "$BASE/hummingbot/conf/conf_client.yml.bak" \
  "Manual backup file. The seed script never creates .bak files."

echo ""
echo "--- Empty unused directories ---"
if [ -d "$BASE/dashboard/pages" ] && [ -z "$(ls -A "$BASE/dashboard/pages" 2>/dev/null)" ]; then
  remove_item "$BASE/dashboard/pages" \
    "Empty directory, not mounted in compose."
fi

echo ""
echo "--- MongoDB: fix Docker-created root-owned data dir ---"
# If Docker created mongodb/data as root before setup.sh ran, fix ownership
if [ -d "$BASE/mongodb/data" ]; then
  OWNER="$(stat -c '%u' "$BASE/mongodb/data" 2>/dev/null || echo "unknown")"
  if [ "$OWNER" = "0" ]; then
    echo "  FIX:    $BASE/mongodb/data (owned by root, should be 999:999)"
    if ! $DRY_RUN; then
      chown -R 999:999 "$BASE/mongodb/data" 2>/dev/null || true
      echo "          → Ownership fixed to 999:999 (mongodb)."
    fi
  else
    echo "  ✓ $BASE/mongodb/data ownership OK (uid=$OWNER)."
  fi
else
  echo "  ○ $BASE/mongodb/data does not exist yet (will be created by setup.sh or seed)."
fi

echo ""
echo "--- Stale MongoDB pre-upgrade backups ---"
# version_aware_seed creates .pre_upgrade_* dirs — clean very old ones
for old_backup in "$BASE"/mongodb/data.pre_upgrade_*; do
  if [ -d "$old_backup" ]; then
    remove_item "$old_backup" \
      "Stale pre-upgrade MongoDB data backup."
  fi
done

echo ""
echo "--- Install updated bootstrap scripts ---"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Core seed scripts
for script in hummingbot_seed.sh seed_helpers.sh; do
  src="$SCRIPT_DIR/$script"
  dst="$BASE/bootstrap/$script"
  if [ -f "$src" ]; then
    echo "  UPDATE: $dst"
    if ! $DRY_RUN; then
      cp "$src" "$dst"
      chmod 755 "$dst"
      echo "          → Installed."
    fi
  else
    echo "  SKIP: $src not found in current directory."
  fi
done

# Candle ingestion files (look in quantslab/ subdir or current dir)
for ingest_file in candle_ingest.py candle_ingest_config.yaml; do
  src=""
  for candidate in \
    "$SCRIPT_DIR/quantslab/$ingest_file" \
    "$SCRIPT_DIR/$ingest_file"; do
    if [ -f "$candidate" ]; then
      src="$candidate"
      break
    fi
  done

  dst="$BASE/bootstrap/$ingest_file"
  if [ -n "$src" ]; then
    # Only update .py unconditionally; preserve user's config.yaml if it exists
    if [ "$ingest_file" = "candle_ingest_config.yaml" ] && [ -f "$dst" ]; then
      echo "  KEEP:   $dst (user config — not overwriting)"
    else
      echo "  UPDATE: $dst"
      if ! $DRY_RUN; then
        cp "$src" "$dst"
        chmod 644 "$dst"
        echo "          → Installed."
      fi
    fi
  else
    echo "  SKIP: $ingest_file not found."
  fi
done

echo ""
echo "--- Ensure MongoDB data directory exists with correct permissions ---"
if [ ! -d "$BASE/mongodb/data" ]; then
  echo "  CREATE: $BASE/mongodb/data"
  if ! $DRY_RUN; then
    mkdir -p "$BASE/mongodb/data"
    chown -R 999:999 "$BASE/mongodb/data" 2>/dev/null || true
    echo "          → Created with mongodb ownership."
  fi
else
  echo "  ✓ $BASE/mongodb/data exists."
fi

echo ""
echo "--- Check for missing .password_verification ---"
PW_FILE="$BASE/hummingbot/conf/.password_verification"
if [ ! -f "$PW_FILE" ]; then
  echo "  ⚠ MISSING: $PW_FILE"
  echo "    This will be created by hummingbot-password-init on next compose up."
  echo "    If it keeps failing, check: docker compose logs hummingbot-password-init"
else
  echo "  ✓ $PW_FILE exists."
fi

echo ""
echo "--- Validate .env has MongoDB variables ---"
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  for var in MONGO_ROOT_PASSWORD MONGO_EXPRESS_PASSWORD; do
    val="$(grep "^${var}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$val" ]; then
      echo "  ⚠ MISSING in .env: $var"
    else
      echo "  ✓ $var is set."
    fi
  done
else
  echo "  ⚠ No .env file found at $ENV_FILE"
fi

echo ""
if $DRY_RUN; then
  echo "============================================"
  echo "  Dry run complete. Run with --apply to execute."
  echo "============================================"
else
  echo "============================================"
  echo "  Cleanup complete!"
  echo "  Next: docker compose -f hummingbot_App.yaml up -d"
  echo "============================================"
fi
