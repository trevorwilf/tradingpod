#!/bin/sh
set -eu

# Optional: strip CR/SOH from injected env values (harmless if not present)
ADMIN_USER_ID="$(printf %s "${ADMIN_USER_ID:-}" | tr -d '\r\001' | sed "s/^'//;s/'$//")"
TELEGRAM_TOKEN="$(printf %s "${TELEGRAM_TOKEN:-}" | tr -d '\r\001' | sed "s/^'//;s/'$//")"

DASHBOARD_CRED="/humming_dir/dashboard/credentials.yml"
EMQX_ETC="/humming_dir/emqx/etc"
API_CONNECTORS="/humming_dir/api/data/bots/credentials/master_account/connectors"
CONDOR_CONFIG="/humming_dir/condor/config.yml"

echo "=== mount check ==="
ls -la /humming_dir || true

echo "=== creating dashboard creds ==="
mkdir -p "$(dirname "$DASHBOARD_CRED")"
if [ ! -f "$DASHBOARD_CRED" ]; then
  printf "username: admin\npassword: admin\n" > "$DASHBOARD_CRED"
fi

echo "=== seeding emqx etc ==="
mkdir -p "$EMQX_ETC"
if [ -z "$(ls -A "$EMQX_ETC" 2>/dev/null || true)" ]; then
  cp -a /opt/emqx/etc/. "$EMQX_ETC/"
fi

echo "=== creating api folders ==="
mkdir -p "$API_CONNECTORS"

echo "=== creating condor config ==="
mkdir -p "$(dirname "$CONDOR_CONFIG")"
if [ ! -f "$CONDOR_CONFIG" ]; then
  printf 'token: "%s"\nadmin_id: %s\nservers: {}\ndefault_server: null\nusers: {}\nserver_access: {}\nchat_defaults: {}\naudit_log: []\n' \
    "$TELEGRAM_TOKEN" "$ADMIN_USER_ID" > "$CONDOR_CONFIG"
fi

chmod -R 777 /humming_dir || true
echo "Pre-flight check complete."