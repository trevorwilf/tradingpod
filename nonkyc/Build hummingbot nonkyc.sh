#!/bin/bash
set -euo pipefail

# =============================================================================
# build_hummingbot_nonkyc.sh
#
# Builds a custom hummingbot Docker image that includes the NonKYC exchange
# connector on top of the latest official hummingbot codebase.
#
# How it works:
#   1. Clones the official hummingbot/hummingbot repo (latest master)
#   2. Clones the NonKYCExchange/hummingbot fork (sparse — connector only)
#   3. Copies the nonkyc connector into the official tree
#   4. Verifies the connector structure
#   5. Builds a Docker image tagged for your Trading Pod compose
#
# Usage:
#   chmod +x build_hummingbot_nonkyc.sh
#   ./build_hummingbot_nonkyc.sh              # build with defaults
#   ./build_hummingbot_nonkyc.sh --tag v2     # custom tag suffix
#   ./build_hummingbot_nonkyc.sh --no-cache   # force full Docker rebuild
#
# Re-run any time to pick up upstream updates from either repo.
# =============================================================================

# ── Configuration ──────────────────────────────────────────────────────────

OFFICIAL_REPO="https://github.com/hummingbot/hummingbot.git"
OFFICIAL_BRANCH="master"

NONKYC_REPO="https://github.com/NonKYCExchange/hummingbot.git"
NONKYC_BRANCH="master"

# Connector path inside the hummingbot source tree
CONNECTOR_REL_PATH="hummingbot/connector/exchange/nonkyc"

# Docker image name — this is what your compose file should reference
IMAGE_NAME="hummingbot-nonkyc"
IMAGE_TAG="latest"

# Working directory for the build
BUILD_DIR="${BUILD_DIR:-/tmp/hummingbot-nonkyc-build}"

# Docker build flags
DOCKER_BUILD_FLAGS=""

# ── Parse CLI args ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)      IMAGE_TAG="$2"; shift 2 ;;
    --tag=*)    IMAGE_TAG="${1#*=}"; shift ;;
    --no-cache) DOCKER_BUILD_FLAGS="--no-cache"; shift ;;
    --dir)      BUILD_DIR="$2"; shift 2 ;;
    --dir=*)    BUILD_DIR="${1#*=}"; shift ;;
    --help|-h)
      echo "Usage: $0 [--tag TAG] [--no-cache] [--dir BUILD_DIR]"
      echo ""
      echo "  --tag TAG     Docker image tag (default: latest)"
      echo "  --no-cache    Force full Docker rebuild"
      echo "  --dir DIR     Working directory (default: /tmp/hummingbot-nonkyc-build)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Functions ──────────────────────────────────────────────────────────────

log()  { echo "[build] $*"; }
warn() { echo "[build] ⚠  $*"; }
die()  { echo "[build] ✗  $*" >&2; exit 1; }
ok()   { echo "[build] ✓  $*"; }

check_prereqs() {
  for cmd in git docker; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found."
  done
  ok "Prerequisites: git, docker"
}

# ── Main ───────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Hummingbot + NonKYC Connector — Custom Docker Build        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

check_prereqs

OFFICIAL_DIR="$BUILD_DIR/official"
NONKYC_DIR="$BUILD_DIR/nonkyc-fork"

mkdir -p "$BUILD_DIR"

# ── Step 1: Clone / update official repo ───────────────────────────────────

log "Step 1/5: Official hummingbot repo"
if [ -d "$OFFICIAL_DIR/.git" ]; then
  log "  Updating existing clone..."
  cd "$OFFICIAL_DIR"
  git fetch origin "$OFFICIAL_BRANCH" --depth=1
  git reset --hard "origin/$OFFICIAL_BRANCH"
  git clean -fdx
else
  log "  Cloning $OFFICIAL_REPO ($OFFICIAL_BRANCH)..."
  rm -rf "$OFFICIAL_DIR"
  git clone --depth=1 --branch "$OFFICIAL_BRANCH" "$OFFICIAL_REPO" "$OFFICIAL_DIR"
fi
cd "$OFFICIAL_DIR"
OFFICIAL_SHA="$(git rev-parse --short HEAD)"
ok "Official repo at $OFFICIAL_SHA"

# ── Step 2: Sparse-clone NonKYC fork (connector only) ─────────────────────

log "Step 2/5: NonKYC connector from fork"
if [ -d "$NONKYC_DIR/.git" ]; then
  log "  Updating existing sparse clone..."
  cd "$NONKYC_DIR"
  git fetch origin "$NONKYC_BRANCH" --depth=1
  git reset --hard "origin/$NONKYC_BRANCH"
else
  log "  Sparse-cloning $NONKYC_REPO..."
  rm -rf "$NONKYC_DIR"
  git clone --depth=1 --filter=blob:none --sparse \
    --branch "$NONKYC_BRANCH" "$NONKYC_REPO" "$NONKYC_DIR"
  cd "$NONKYC_DIR"
  git sparse-checkout set "$CONNECTOR_REL_PATH"
fi
cd "$NONKYC_DIR"
NONKYC_SHA="$(git rev-parse --short HEAD)"
ok "NonKYC fork at $NONKYC_SHA"

# ── Step 3: Verify connector structure ─────────────────────────────────────

log "Step 3/5: Verifying connector structure"

SRC_CONNECTOR="$NONKYC_DIR/$CONNECTOR_REL_PATH"
DST_CONNECTOR="$OFFICIAL_DIR/$CONNECTOR_REL_PATH"

if [ ! -d "$SRC_CONNECTOR" ]; then
  die "Connector not found at $SRC_CONNECTOR"
fi

# Check for expected key files
EXPECTED_FILES=(
  "__init__.py"
)
for f in "${EXPECTED_FILES[@]}"; do
  if [ ! -f "$SRC_CONNECTOR/$f" ]; then
    warn "Expected file missing: $f (this might be OK if the connector uses a different structure)"
  fi
done

# List what we're copying
log "  Connector files found:"
find "$SRC_CONNECTOR" -type f -name '*.py' | sort | while read -r f; do
  echo "    $(basename "$f")"
done

FILE_COUNT="$(find "$SRC_CONNECTOR" -type f -name '*.py' | wc -l)"
if [ "$FILE_COUNT" -lt 3 ]; then
  die "Only $FILE_COUNT .py files found — connector seems incomplete."
fi
ok "Connector structure looks good ($FILE_COUNT Python files)"

# ── Step 4: Graft connector into official tree ─────────────────────────────

log "Step 4/5: Grafting NonKYC connector into official codebase"

# Remove any existing nonkyc connector (shouldn't exist, but be safe)
if [ -d "$DST_CONNECTOR" ]; then
  warn "Replacing existing nonkyc connector in official tree"
  rm -rf "$DST_CONNECTOR"
fi

# Copy connector
cp -a "$SRC_CONNECTOR" "$DST_CONNECTOR"
ok "Connector copied to $CONNECTOR_REL_PATH"

# Check if there are any other NonKYC-related changes we should look for
# (e.g., test files, conf templates)
log "  Checking for related test files..."
NONKYC_TESTS="$NONKYC_DIR/test/hummingbot/connector/exchange/nonkyc"
if [ -d "$NONKYC_TESTS" ]; then
  OFFICIAL_TESTS="$OFFICIAL_DIR/test/hummingbot/connector/exchange/nonkyc"
  mkdir -p "$(dirname "$OFFICIAL_TESTS")"
  cp -a "$NONKYC_TESTS" "$OFFICIAL_TESTS"
  ok "Test files copied"
else
  log "  No test directory found in fork (not critical)"
fi

# Check for connector config template
log "  Checking for conf template..."
for tpl_dir in \
  "$NONKYC_DIR/hummingbot/templates" \
  "$NONKYC_DIR/conf/connectors"; do
  if [ -d "$tpl_dir" ]; then
    for tpl in "$tpl_dir"/*nonkyc*; do
      [ -f "$tpl" ] || continue
      tpl_name="$(basename "$tpl")"
      dst_tpl="$OFFICIAL_DIR/$(echo "$tpl" | sed "s|$NONKYC_DIR/||")"
      mkdir -p "$(dirname "$dst_tpl")"
      cp -a "$tpl" "$dst_tpl"
      ok "Template copied: $tpl_name"
    done
  fi
done

# ── Step 5: Build Docker image ────────────────────────────────────────────

log "Step 5/5: Building Docker image"
cd "$OFFICIAL_DIR"

FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"
log "  Image: $FULL_TAG"
log "  Context: $OFFICIAL_DIR"
log "  Dockerfile: $OFFICIAL_DIR/Dockerfile"

if [ ! -f "$OFFICIAL_DIR/Dockerfile" ]; then
  die "Dockerfile not found in official repo root!"
fi

docker build $DOCKER_BUILD_FLAGS \
  -t "$FULL_TAG" \
  -f Dockerfile \
  --label "org.opencontainers.image.description=hummingbot + nonkyc connector" \
  --label "nonkyc.official.sha=$OFFICIAL_SHA" \
  --label "nonkyc.connector.sha=$NONKYC_SHA" \
  --label "nonkyc.build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  .

BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
  die "Docker build failed with exit code $BUILD_EXIT"
fi

ok "Image built: $FULL_TAG"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Build Complete!                                            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Image:     $FULL_TAG"
echo "║  Official:  hummingbot/hummingbot @ $OFFICIAL_SHA"
echo "║  NonKYC:    NonKYCExchange/hummingbot @ $NONKYC_SHA"
echo "║                                                            ║"
echo "║  To use in your Trading Pod compose, change:               ║"
echo "║                                                            ║"
echo "║    hummingbot:                                             ║"
echo "║      image: $FULL_TAG"
echo "║                                                            ║"
echo "║  To rebuild after upstream updates:                        ║"
echo "║    $0"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Show image size
docker image inspect "$FULL_TAG" --format='Image size: {{.Size}}' 2>/dev/null | \
  awk '{printf "Image size: %.0f MB\n", $3/1024/1024}' || true

docker tag hummingbot-nonkyc:latest hummingbot/hummingbot:latest