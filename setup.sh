#!/bin/bash
set -euo pipefail

# =============================================================================
# setup.sh — One-time setup for a fresh Hummingbot Trading Pod
#
# Run ONCE on a new server before your first `docker compose up -d`.
# Places the seed scripts and ingestion files that the containers need.
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

# --- Step 1: Create base directories ---
echo "[1/7] Creating base directories"
sudo mkdir -p "$BASE_DIR/bootstrap"
sudo mkdir -p "$BASE_DIR/mongodb/data"

# --- Step 2: Copy seed scripts ---
echo "[2/7] Installing seed scripts"

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

# --- Step 3: Copy candle ingestion files ---
echo "[3/7] Installing candle ingestion files"

# Look in quantslab/ subdirectory first, then current directory
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

  dst="$BASE_DIR/bootstrap/$ingest_file"
  if [ -n "$src" ]; then
    sudo cp "$src" "$dst"
    sudo chmod 644 "$dst"
    echo "      → $dst"
  else
    echo "      SKIP: $ingest_file not found (candle ingestion optional)"
  fi
done

# --- Step 4: Create .env ---
echo "[4/7] Checking .env file"
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

# --- Step 5: Permissions ---
echo "[5/7] Setting permissions on $BASE_DIR"
sudo chmod -R 777 "$BASE_DIR" 2>/dev/null || true

# MongoDB data dir needs specific ownership (mongo:7 image UID 999)
sudo chown -R 999:999 "$BASE_DIR/mongodb/data" 2>/dev/null || true

# --- Step 6: Verify ---
echo "[6/7] Verifying required files..."
ALL_OK=true

for f in "$BASE_DIR/bootstrap/hummingbot_seed.sh" "$BASE_DIR/bootstrap/seed_helpers.sh"; do
  if [ -f "$f" ]; then
    echo "      ✓ $(basename "$f")"
  else
    echo "      ✗ MISSING: $f"
    ALL_OK=false
  fi
done

echo "      Verifying optional files..."
for f in "$BASE_DIR/bootstrap/candle_ingest.py" "$BASE_DIR/bootstrap/candle_ingest_config.yaml"; do
  if [ -f "$f" ]; then
    echo "      ✓ $(basename "$f")"
  else
    echo "      ○ NOT FOUND: $(basename "$f") (candle ingestion won't work until placed)"
  fi
done

# --- Step 7: Summary ---
echo "[7/7] Checking .env for required variables..."
ENV_FILE="$SCRIPT_DIR/.env"
MISSING_VARS=""
if [ -f "$ENV_FILE" ]; then
  for var in WIREGUARD_PRIVATE_KEY POSTGRES_PASSWORD GATEWAY_PASSPHRASE CONFIG_PASSWORD MONGO_ROOT_PASSWORD; do
    val="$(grep "^${var}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$val" ]; then
      MISSING_VARS="$MISSING_VARS $var"
    fi
  done
fi

echo ""
if [ -n "$MISSING_VARS" ]; then
  echo "  ⚠  These .env variables are empty or missing:"
  for v in $MISSING_VARS; do
    echo "       - $v"
  done
  echo ""
fi

echo "============================================"
if $ALL_OK; then
  echo "  Setup complete!"
else
  echo "  Setup complete with warnings (see above)."
fi
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Edit .env and fill in your credentials"
echo "  2. (Optional) Edit bootstrap/candle_ingest_config.yaml for your pairs"
echo "  3. docker compose -f hummingbot_App.yaml up -d"
echo "  4. Watch init containers:"
echo "     docker compose logs -f hummingbot-seed hummingbot-api-init gateway-init hummingbot-password-init"
echo "  5. Watch candle ingestion (first backfill takes a few minutes):"
echo "     docker logs -f hummingbot-candle-ingest"
echo ""
