#!/bin/bash
set -euo pipefail

# =============================================================================
# setup.sh — One-time setup for a fresh Hummingbot Trading Pod
#
# Run ONCE on a new server before your first `docker compose up -d`.
# Places the seed scripts that the init containers need to find.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
# =============================================================================

BASE_DIR="/mnt/sharedrive/apps/hummingbot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Hummingbot Trading Pod — Fresh Setup"
echo "============================================"
echo ""

# --- Step 1: Create base directory ---
echo "[1/5] Creating base directory: $BASE_DIR/bootstrap"
sudo mkdir -p "$BASE_DIR/bootstrap"

# --- Step 2: Copy seed scripts ---
echo "[2/5] Installing seed scripts"

for script in hummingbot_seed.sh seed_helpers.sh; do
  src="$SCRIPT_DIR/$script"
  dst="$BASE_DIR/bootstrap/$script"
  if [ ! -f "$src" ]; then
    echo "      ERROR: Cannot find $src"
    exit 1
  fi
  sudo cp "$src" "$dst"
  sudo chmod 755 "$dst"
  echo "      → $dst"
done

# --- Step 3: Create .env ---
echo "[3/5] Checking .env file"
if [ -f "$SCRIPT_DIR/.env" ]; then
  echo "      .env already exists — not overwriting."
else
  if [ -f "$SCRIPT_DIR/env.example" ]; then
    cp "$SCRIPT_DIR/env.example" "$SCRIPT_DIR/.env"
    echo "      Created .env from env.example."
  else
    echo "      WARNING: No env.example found. Create .env manually."
  fi
fi

# --- Step 4: Permissions ---
echo "[4/5] Setting permissions on $BASE_DIR"
sudo chmod -R 777 "$BASE_DIR" 2>/dev/null || true

# --- Step 5: Verify ---
echo "[5/5] Verifying..."
for f in "$BASE_DIR/bootstrap/hummingbot_seed.sh" "$BASE_DIR/bootstrap/seed_helpers.sh"; do
  if [ -f "$f" ]; then
    echo "      ✓ $(basename "$f")"
  else
    echo "      ✗ MISSING: $f"
  fi
done

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Edit .env and fill in your credentials"
echo "  2. docker compose up -d"
echo "  3. Watch init containers:"
echo "     docker compose logs -f hummingbot-seed hummingbot-api-init gateway-init hummingbot-password-init"
echo ""