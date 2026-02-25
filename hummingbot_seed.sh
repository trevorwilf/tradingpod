#!/bin/sh
set -eu

# -----------------------------------------------------------------------------
# hummingbot_seed.sh  v4.0
#
# One-shot bootstrap (runs in the emqx:5 image). Creates the full directory
# tree + user-owned config files required by the Trading Pod stack.
#
# What this handles:
#   DIRECTORIES — every bind-mount target in the compose
#   USER-OWNED FILES (created once, never overwritten):
#     - dashboard/credentials.yml
#     - hummingbot/conf/conf_client.yml  (+copy to api master_account)
#     - condor/config.yml
#   APP-MANAGED DIRS (version-aware, refreshed on image updates):
#     - emqx/etc/  (from /opt/emqx/etc in this image)
#   FILE MOUNT GUARDS (placeholders to prevent Docker dir-creation bug):
#     - patches/docker_service.py
#
# Handled by OTHER init containers (not this script):
#   - patches/docker_service.py content  → hummingbot-api-init
#   - api/data/bots/controllers/         → hummingbot-api-init
#   - api/data/bots/scripts/             → hummingbot-api-init
#   - gateway/conf/                      → gateway-init
#   - .password_verification             → hummingbot-password-init
# -----------------------------------------------------------------------------

umask 022

# Load shared version-aware seeding functions
HELPERS="/humming_dir/bootstrap/seed_helpers.sh"
if [ -f "$HELPERS" ]; then
  . "$HELPERS"
else
  echo "[seed] ERROR: $HELPERS not found. Run setup.sh first."
  exit 1
fi

# ==================== UTILITIES ====================

sanitize() {
  printf %s "${1:-}" | tr -d '\r\001' | sed "s/^'//;s/'\$//"
}

now_ts() {
  date +%s 2>/dev/null || echo 0
}

log() {
  echo "[seed] $*"
}

ensure_dir() {
  mkdir -p "$1"
}

ensure_file_from_stdin() {
  file="$1"
  if [ -d "$file" ]; then
    ts="$(now_ts)"
    log "WARNING: $file is a directory (Docker artefact). Moving aside."
    mv "$file" "${file}.bak_dir_${ts}" 2>/dev/null || true
  fi
  ensure_dir "$(dirname "$file")"
  if [ ! -s "$file" ]; then
    cat > "$file"
  fi
}

# ==================== EMQX VERSION DETECTION ====================

get_emqx_version() {
  if [ -n "${SEED_IMAGE_VERSION:-}" ]; then
    printf %s "$SEED_IMAGE_VERSION"
    return
  fi
  if [ -f /opt/emqx/releases/emqx_vars ]; then
    ver="$(grep 'REL_VSN=' /opt/emqx/releases/emqx_vars 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
    if [ -n "$ver" ]; then
      printf %s "emqx-$ver"
      return
    fi
  fi
  # Fallback: fingerprint
  fingerprint_dir /opt/emqx/etc
}

# ==================== ENVIRONMENT ====================

ADMIN_USER_ID="$(sanitize "${ADMIN_USER_ID:-}")"
TELEGRAM_TOKEN="$(sanitize "${TELEGRAM_TOKEN:-}")"

BASE="/humming_dir"

# ==================== PATH DEFINITIONS ====================

GLUETUN_DIR="$BASE/gluetun"

HBOT_BASE="$BASE/hummingbot"
HBOT_CONF="$HBOT_BASE/conf"
HBOT_LOGS="$HBOT_BASE/logs"
HBOT_DATA="$HBOT_BASE/data"
HBOT_CERTS="$HBOT_BASE/certs"
HBOT_SCRIPTS="$HBOT_BASE/scripts"
HBOT_CONTROLLERS="$HBOT_BASE/controllers"

GATEWAY_BASE="$BASE/gateway"
GATEWAY_CONF="$GATEWAY_BASE/conf"
GATEWAY_LOGS="$GATEWAY_BASE/logs"
GATEWAY_CERTS="$GATEWAY_BASE/certs"

POSTGRES_DATA="$BASE/postgres/data"

EMQX_BASE="$BASE/emqx"
EMQX_DATA="$EMQX_BASE/data"
EMQX_LOG="$EMQX_BASE/log"
EMQX_ETC="$EMQX_BASE/etc"

API_BOTS="$BASE/api/data/bots"
API_CONNECTORS="$API_BOTS/credentials/master_account/connectors"
API_MASTER="$API_BOTS/credentials/master_account"

MCP_DIR="$BASE/controllers/mcp"

DASHBOARD_CRED="$BASE/dashboard/credentials.yml"

CONDOR_BASE="$BASE/condor"
CONDOR_DATA="$CONDOR_BASE/data"
CONDOR_ROUTINES="$CONDOR_BASE/routines"
CONDOR_CONFIG="$CONDOR_BASE/config.yml"

BOOTSTRAP_DIR="$BASE/bootstrap"
PATCHES_DIR="$BASE/patches"

# ==================== PRE-FLIGHT ====================

log "=== mount check ==="
if [ ! -d "$BASE" ]; then
  log "ERROR: $BASE is not a directory (bind mount missing?)."
  exit 1
fi
ls -la "$BASE" || true

# ==================== DIRECTORY TREE ====================

log "=== creating directory tree ==="
ensure_dir "$BOOTSTRAP_DIR"
ensure_dir "$PATCHES_DIR"
ensure_dir "$GLUETUN_DIR"

ensure_dir "$HBOT_CONF"
ensure_dir "$HBOT_LOGS"
ensure_dir "$HBOT_DATA"
ensure_dir "$HBOT_CERTS"
ensure_dir "$HBOT_SCRIPTS"
ensure_dir "$HBOT_CONTROLLERS"

ensure_dir "$GATEWAY_CONF"
ensure_dir "$GATEWAY_LOGS"
ensure_dir "$GATEWAY_CERTS"

ensure_dir "$POSTGRES_DATA"

ensure_dir "$EMQX_DATA"
ensure_dir "$EMQX_LOG"
ensure_dir "$EMQX_ETC"

ensure_dir "$API_BOTS"
ensure_dir "$API_CONNECTORS"
ensure_dir "$API_MASTER"

ensure_dir "$MCP_DIR"

ensure_dir "$(dirname "$DASHBOARD_CRED")"

ensure_dir "$CONDOR_DATA"
ensure_dir "$CONDOR_ROUTINES"
ensure_dir "$(dirname "$CONDOR_CONFIG")"

# ==================== FILE MOUNT GUARDS ====================

log "=== file mount guards ==="

DOCKER_SVC_PY="$PATCHES_DIR/docker_service.py"
if [ -d "$DOCKER_SVC_PY" ]; then
  ts="$(now_ts)"
  log "WARNING: $DOCKER_SVC_PY is a directory. Moving aside."
  mv "$DOCKER_SVC_PY" "${DOCKER_SVC_PY}.bak_dir_${ts}" 2>/dev/null || true
fi
if [ ! -f "$DOCKER_SVC_PY" ]; then
  log "Creating placeholder: $DOCKER_SVC_PY"
  printf '# Placeholder — replaced by hummingbot-api-init on first run.\nraise RuntimeError("docker_service.py not yet extracted")\n' > "$DOCKER_SVC_PY"
fi

# ==================== USER-OWNED FILES ====================

log "=== creating dashboard creds (if missing/empty) ==="
ensure_file_from_stdin "$DASHBOARD_CRED" <<'__DASH_CREDS__'
username: admin
password: admin
__DASH_CREDS__

log "=== creating conf_client.yml (if missing/empty) ==="
ensure_file_from_stdin "$HBOT_CONF/conf_client.yml" <<'__CONF_CLIENT__'
####################################
###   client_config_map config   ###
####################################

instance_id: null

fetch_pairs_from_all_exchanges: false

log_level: INFO

debug_console: false

strategy_report_interval: 900.0

logger_override_whitelist:
- hummingbot.strategy.arbitrage
- hummingbot.strategy.cross_exchange_market_making
- conf

log_file_path: /home/hummingbot/logs

kill_switch_mode: {}

autofill_import: disabled

mqtt_bridge:
  mqtt_host: 127.0.0.1
  mqtt_port: 1883
  mqtt_username: ''
  mqtt_password: ''
  mqtt_namespace: hbot
  mqtt_ssl: false
  mqtt_logger: true
  mqtt_notifier: true
  mqtt_commands: true
  mqtt_events: true
  mqtt_external_events: true
  mqtt_autostart: true

send_error_logs: true

db_mode:
  db_engine: sqlite

balance_asset_limit: {}

manual_gas_price: 50.0

gateway:
  gateway_api_host: 127.0.0.1
  gateway_api_port: '15888'
  gateway_use_ssl: false

anonymized_metrics_mode:
  anonymized_metrics_interval_min: 15.0

rate_oracle_source:
  name: binance

global_token:
  global_token_name: USDT
  global_token_symbol: $

rate_limits_share_pct: 100.0

commands_timeout:
  create_command_timeout: 10.0
  other_commands_timeout: 30.0

tables_format: psql

paper_trade:
  paper_trade_exchanges:
  - binance
  - kucoin
  - kraken
  - gate_io
  - mexc
  paper_trade_account_balance:
    BTC: 1.0
    USDT: 100000.0
    USDC: 100000.0
    ETH: 20.0
    WETH: 20.0
    SOL: 100.0
    DOGE: 1000000.0
    HBOT: 10000000.0
    SAL: 10000.0

color:
  top_pane: '#000000'
  bottom_pane: '#000000'
  output_pane: '#262626'
  input_pane: '#1C1C1C'
  logs_pane: '#121212'
  terminal_primary: '#5FFFD7'
  primary_label: '#5FFFD7'
  secondary_label: '#FFFFFF'
  success_label: '#5FFFD7'
  warning_label: '#FFFF00'
  info_label: '#5FD7FF'
  error_label: '#FF0000'
  gold_label: '#FFD700'
  silver_label: '#C0C0C0'
  bronze_label: '#CD7F32'

tick_size: 1.0

market_data_collection:
  market_data_collection_enabled: false
  market_data_collection_interval: 60
  market_data_collection_depth: 20
__CONF_CLIENT__

log "=== copying conf_client.yml to API master_account ==="
if [ -f "$HBOT_CONF/conf_client.yml" ]; then
  cp -n "$HBOT_CONF/conf_client.yml" "$API_MASTER/conf_client.yml" 2>/dev/null || true
fi

log "=== creating condor config (if missing/empty) ==="
ADMIN_ID_LINE="admin_id: null"
case "$ADMIN_USER_ID" in
  "") ADMIN_ID_LINE="admin_id: null" ;;
  *[!0-9]*) ADMIN_ID_LINE="admin_id: \"$ADMIN_USER_ID\"" ;;
  *) ADMIN_ID_LINE="admin_id: $ADMIN_USER_ID" ;;
esac

ensure_file_from_stdin "$CONDOR_CONFIG" <<__CONDOR_CFG__
token: "$TELEGRAM_TOKEN"
$ADMIN_ID_LINE
servers: {}
default_server: null
users: {}
server_access: {}
chat_defaults: {}
audit_log: []
__CONDOR_CFG__

# ==================== APP-MANAGED DIRS (VERSION-AWARE) ====================

log "=== version-aware seed: EMQX etc ==="
if [ -d /opt/emqx/etc ]; then
  emqx_ver="$(get_emqx_version)"
  version_aware_seed /opt/emqx/etc "$EMQX_ETC" "$emqx_ver"
else
  log "WARNING: /opt/emqx/etc not found — skipping EMQX seed."
fi

# ==================== PERMISSIONS ====================

log "=== permissions ==="
chmod -R 777 "$BASE" 2>/dev/null || true

chown -R 999:999 "$POSTGRES_DATA" 2>/dev/null || true
chmod 700 "$POSTGRES_DATA" 2>/dev/null || true

EMQX_UID="$(id -u emqx 2>/dev/null || true)"
EMQX_GID="$(id -g emqx 2>/dev/null || true)"
if [ -n "${EMQX_UID:-}" ] && [ -n "${EMQX_GID:-}" ]; then
  chown -R "$EMQX_UID:$EMQX_GID" "$EMQX_BASE" 2>/dev/null || true
fi

log "=== Pre-flight check complete. ==="