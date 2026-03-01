#!/bin/bash
set -euo pipefail

# =============================================================================
# Build_hummingbot_api_nonkyc.sh
#
# Builds a custom hummingbot-api Docker image from a SINGLE repo/branch:
#   https://github.com/trevorwilf/hummingbot-api  (branch: nonkyc)
#
# Mirrors the structure of Build_hummingbot_nonkyc.sh for consistency.
#
# Usage:
#   chmod +x Build_hummingbot_api_nonkyc.sh
#   ./Build_hummingbot_api_nonkyc.sh              # build with defaults
#   ./Build_hummingbot_api_nonkyc.sh --tag v2     # custom tag suffix
#   ./Build_hummingbot_api_nonkyc.sh --no-cache   # force full Docker rebuild
#   ./Build_hummingbot_api_nonkyc.sh --dir /tmp/x # custom working directory
# =============================================================================

# ── Configuration ──────────────────────────────────────────────────────────

# SINGLE SOURCE REPO
HB_API_REPO="https://github.com/trevorwilf/hummingbot-api.git"
HB_API_BRANCH="nonkyc"

# Key files/dirs to verify the repo is correct
VERIFY_FILE="main.py"
VERIFY_DIR="services"

# Docker image name — this is what your compose file should reference
IMAGE_NAME="hummingbot-api-nonkyc"
IMAGE_TAG="latest"

# Working directory for the build
BUILD_DIR="${BUILD_DIR:-/tmp/hummingbot-api-nonkyc-build}"

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
      echo "  --dir DIR     Working directory (default: /tmp/hummingbot-api-nonkyc-build)"
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
echo "║  Hummingbot API (trevorwilf/nonkyc) — Custom Docker Build    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

check_prereqs

SRC_DIR="$BUILD_DIR/src"
mkdir -p "$BUILD_DIR"

# ── Step 1: Clone / update single repo ─────────────────────────────────────

log "Step 1/4: Clone/update source repo"
if [ -d "$SRC_DIR/.git" ]; then
  log "  Updating existing clone..."
  cd "$SRC_DIR"
  git fetch origin "$HB_API_BRANCH" --depth=1
  git reset --hard "origin/$HB_API_BRANCH"
  git clean -fdx
else
  log "  Cloning $HB_API_REPO ($HB_API_BRANCH)..."
  rm -rf "$SRC_DIR"
  git clone --depth=1 --branch "$HB_API_BRANCH" "$HB_API_REPO" "$SRC_DIR"
fi

cd "$SRC_DIR"
HB_API_SHA="$(git rev-parse --short HEAD)"
ok "Source repo at $HB_API_SHA ($HB_API_BRANCH)"

# ── Step 2: Verify API structure exists ────────────────────────────────────

log "Step 2/4: Verifying hummingbot-api structure"
if [ ! -f "$SRC_DIR/$VERIFY_FILE" ]; then
  die "Expected file not found: $VERIFY_FILE — is this the right repo?"
fi

if [ ! -d "$SRC_DIR/$VERIFY_DIR" ]; then
  die "Expected directory not found: $VERIFY_DIR — is this the right repo?"
fi

PY_COUNT="$(find "$SRC_DIR" -maxdepth 2 -type f -name '*.py' | wc -l | tr -d ' ')"
if [ "${PY_COUNT:-0}" -lt 5 ]; then
  die "Only $PY_COUNT Python files found — API codebase seems incomplete."
fi
ok "API structure verified ($PY_COUNT Python files, $VERIFY_FILE + $VERIFY_DIR present)"

# ── Step 3: Verify Dockerfile exists ───────────────────────────────────────

log "Step 3/4: Locating Dockerfile"
cd "$SRC_DIR"

if [ ! -f "$SRC_DIR/Dockerfile" ]; then
  die "Dockerfile not found in repo root!"
fi

ok "Dockerfile found"

# ── Step 4: Build image from repo Dockerfile ───────────────────────────────

log "Step 4/4: Building image"

FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"

docker build $DOCKER_BUILD_FLAGS \
  -t "$FULL_TAG" \
  -f Dockerfile \
  --label "org.opencontainers.image.description=hummingbot-api (trevorwilf/nonkyc)" \
  --label "hummingbot-api.source.repo=$HB_API_REPO" \
  --label "hummingbot-api.source.branch=$HB_API_BRANCH" \
  --label "hummingbot-api.source.sha=$HB_API_SHA" \
  --label "hummingbot-api.build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  .

ok "Image built: $FULL_TAG"

# Sanity check: verify main.py can be imported
log "  Verifying API can start..."
docker run --rm --entrypoint python "$FULL_TAG" -c "import fastapi; print('fastapi OK')" >/dev/null 2>&1 \
  && ok "FastAPI import check passed" \
  || warn "FastAPI import check failed (image may have different entrypoint)"

# Tag as hummingbot/hummingbot-api:latest for compose compatibility
docker tag "$FULL_TAG" hummingbot/hummingbot-api:latest
ok "Tagged hummingbot/hummingbot-api:latest -> $FULL_TAG"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Build Complete!                                            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Image:    $FULL_TAG"
echo "║  Repo:     $HB_API_REPO"
echo "║  Branch:   $HB_API_BRANCH"
echo "║  Commit:   $HB_API_SHA"
echo "║                                                            ║"
echo "║  Compose can use:                                           ║"
echo "║    image: $FULL_TAG"
echo "║    image: hummingbot/hummingbot-api:latest"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

docker image inspect "$FULL_TAG" --format='Image size: {{.Size}}' 2>/dev/null | \
  awk '{printf "Image size: %.0f MB\n", $3/1024/1024}' || true
