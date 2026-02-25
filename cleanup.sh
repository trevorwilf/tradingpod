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
echo "--- Install updated bootstrap scripts ---"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
if $DRY_RUN; then
  echo "============================================"
  echo "  Dry run complete. Run with --apply to execute."
  echo "============================================"
else
  echo "============================================"
  echo "  Cleanup complete!"
  echo "  Next: docker compose up -d"
  echo "============================================"
fi