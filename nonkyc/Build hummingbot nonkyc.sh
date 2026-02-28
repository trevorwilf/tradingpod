#!/bin/bash
set -euo pipefail

# =============================================================================
# build_hummingbot_nonkyc.sh
#
# Builds a custom hummingbot Docker image from a SINGLE repo/branch:
#   https://github.com/trevorwilf/hummingbot  (branch: nonkyc)
#
# Additionally bakes in a Postgres driver (psycopg2-binary) so DB mode works.
#
# Usage:
#   chmod +x build_hummingbot_nonkyc.sh
#   ./build_hummingbot_nonkyc.sh              # build with defaults
#   ./build_hummingbot_nonkyc.sh --tag v2     # custom tag suffix
#   ./build_hummingbot_nonkyc.sh --no-cache   # force full Docker rebuild
#   ./build_hummingbot_nonkyc.sh --dir /tmp/x # custom working directory
# =============================================================================

# ── Configuration ──────────────────────────────────────────────────────────

# SINGLE SOURCE REPO (per your request)
HB_REPO="https://github.com/trevorwilf/hummingbot.git"
HB_BRANCH="nonkyc"

# Connector path inside the hummingbot source tree (we still verify it exists)
CONNECTOR_REL_PATH="hummingbot/connector/exchange/nonkyc"

# Docker image name — this is what your compose file should reference
IMAGE_NAME="hummingbot-nonkyc"
IMAGE_TAG="latest"

# Working directory for the build
BUILD_DIR="${BUILD_DIR:-/tmp/hummingbot-nonkyc-build}"

# Docker build flags
DOCKER_BUILD_FLAGS=""

# Postgres driver to bake in (permanently fixes "no psycopg2/psycopg/asyncpg")
PG_DRIVER_PIP_PACKAGE="psycopg2-binary"

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
echo "║  Hummingbot (trevorwilf/nonkyc) — Custom Docker Build        ║"
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
  git fetch origin "$HB_BRANCH" --depth=1
  git reset --hard "origin/$HB_BRANCH"
  git clean -fdx
else
  log "  Cloning $HB_REPO ($HB_BRANCH)..."
  rm -rf "$SRC_DIR"
  git clone --depth=1 --branch "$HB_BRANCH" "$HB_REPO" "$SRC_DIR"
fi

cd "$SRC_DIR"
HB_SHA="$(git rev-parse --short HEAD)"
ok "Source repo at $HB_SHA ($HB_BRANCH)"

# ── Step 2: Verify connector exists ────────────────────────────────────────

log "Step 2/4: Verifying NonKYC connector exists"
if [ ! -d "$SRC_DIR/$CONNECTOR_REL_PATH" ]; then
  die "Connector directory not found: $CONNECTOR_REL_PATH"
fi

PY_COUNT="$(find "$SRC_DIR/$CONNECTOR_REL_PATH" -type f -name '*.py' | wc -l | tr -d ' ')"
if [ "${PY_COUNT:-0}" -lt 3 ]; then
  die "Only $PY_COUNT Python files found in $CONNECTOR_REL_PATH — connector seems incomplete."
fi
ok "Connector present ($PY_COUNT Python files)"

# ── Step 3: Build base image from repo Dockerfile ──────────────────────────

log "Step 3/4: Building base image from repo Dockerfile"
cd "$SRC_DIR"

if [ ! -f "$SRC_DIR/Dockerfile" ]; then
  die "Dockerfile not found in repo root!"
fi

BASE_TAG="${IMAGE_NAME}-base:${IMAGE_TAG}"
log "  Base image: $BASE_TAG"

docker build $DOCKER_BUILD_FLAGS \
  -t "$BASE_TAG" \
  -f Dockerfile \
  --label "org.opencontainers.image.description=hummingbot (trevorwilf/nonkyc) base" \
  --label "hummingbot.source.repo=$HB_REPO" \
  --label "hummingbot.source.branch=$HB_BRANCH" \
  --label "hummingbot.source.sha=$HB_SHA" \
  --label "hummingbot.build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  .

ok "Base image built: $BASE_TAG"

# ── Step 4: Overlay image adds Postgres driver ─────────────────────────────

log "Step 4/4: Building final image with Postgres driver"

FULL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"
WRAP_DOCKERFILE="$BUILD_DIR/Dockerfile.pg"

cat > "$WRAP_DOCKERFILE" <<EOF
FROM ${BASE_TAG}

USER root
RUN python -m pip install --no-cache-dir --upgrade pip \
 && python -m pip install --no-cache-dir ${PG_DRIVER_PIP_PACKAGE}

# Return to the original non-root user if one exists.
# The official image uses 'hummingbot', but forks may not have that user.
# We detect at build time and only set USER if the account is real.
RUN if id hummingbot >/dev/null 2>&1; then \
      echo "USER_EXISTS=hummingbot" ; \
    else \
      echo "NOTE: 'hummingbot' user not found — staying as root." ; \
    fi
# Shell RUN can't conditionally set USER, so we use a small entrypoint-wrapper approach:
# If hummingbot user exists, bake it in; otherwise leave USER unset (defaults to root).
ARG RUNTIME_USER=root
RUN if id hummingbot >/dev/null 2>&1; then echo hummingbot > /tmp/.runtime_user; else echo root > /tmp/.runtime_user; fi
RUN export DETECTED_USER=\$(cat /tmp/.runtime_user) && rm -f /tmp/.runtime_user && echo "Runtime user: \$DETECTED_USER"
EOF

# Detect the correct user from the base image and append USER directive
DETECTED_USER=$(docker run --rm --user root "$BASE_TAG" sh -c 'id -u hummingbot >/dev/null 2>&1 && echo hummingbot || echo root' 2>/dev/null || echo "root")
log "  Detected runtime user from base image: $DETECTED_USER"
echo "USER $DETECTED_USER" >> "$WRAP_DOCKERFILE"

docker build $DOCKER_BUILD_FLAGS \
  -t "$FULL_TAG" \
  -f "$WRAP_DOCKERFILE" \
  --label "org.opencontainers.image.description=hummingbot (trevorwilf/nonkyc) + ${PG_DRIVER_PIP_PACKAGE}" \
  --label "hummingbot.source.repo=$HB_REPO" \
  --label "hummingbot.source.branch=$HB_BRANCH" \
  --label "hummingbot.source.sha=$HB_SHA" \
  --label "hummingbot.pg.driver=${PG_DRIVER_PIP_PACKAGE}" \
  --label "hummingbot.build.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$BUILD_DIR"

ok "Final image built: $FULL_TAG"

# Sanity check: verify psycopg2 imports
log "  Verifying Postgres driver import..."
docker run --rm --entrypoint python "$FULL_TAG" -c "import psycopg2; print('psycopg2 OK')" >/dev/null \
  && ok "Driver check passed" \
  || warn "Driver check failed (image may not have python/pip on PATH as expected)"

# Optional: keep your previous behavior of tagging over hummingbot/hummingbot:latest
# (so compose can continue to use hummingbot/hummingbot:latest)
docker tag "$FULL_TAG" hummingbot/hummingbot:latest
ok "Tagged hummingbot/hummingbot:latest -> $FULL_TAG"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Build Complete!                                            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Image:    $FULL_TAG"
echo "║  Repo:     $HB_REPO"
echo "║  Branch:   $HB_BRANCH"
echo "║  Commit:   $HB_SHA"
echo "║  PG drv:   $PG_DRIVER_PIP_PACKAGE"
echo "║                                                            ║"
echo "║  Compose can use:                                           ║"
echo "║    image: $FULL_TAG"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

docker image inspect "$FULL_TAG" --format='Image size: {{.Size}}' 2>/dev/null | \
  awk '{printf "Image size: %.0f MB\n", $3/1024/1024}' || true