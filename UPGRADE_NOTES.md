# Trading Pod v4.0 — Architecture & Upgrade Notes

## Files in This Repo

```
├── docker-compose.yaml    # The stack definition
├── env.example            # Template for .env
├── hummingbot_seed.sh     # Main bootstrap script (dirs, user configs, EMQX)
├── seed_helpers.sh        # Shared version-aware seeding functions
├── setup.sh               # One-time fresh server setup
├── cleanup.sh             # One-time cleanup for existing servers
└── UPGRADE_NOTES.md       # This file
```

## Fresh Deploy (New Server)

```bash
chmod +x setup.sh
./setup.sh                 # Creates dirs, installs scripts, creates .env
nano .env                  # Fill in credentials
docker compose up -d       # Start everything
docker compose logs -f hummingbot-seed hummingbot-api-init gateway-init hummingbot-password-init
```

## Upgrading an Existing Server to v4

```bash
# 1. Stop the stack
docker compose down

# 2. Run cleanup (dry-run first)
chmod +x cleanup.sh
./cleanup.sh               # Shows what will be removed
./cleanup.sh --apply       # Actually removes + installs new scripts

# 3. Replace compose file
cp docker-compose.yaml /path/to/your/compose/dir/

# 4. Start
docker compose up -d
```

---

## The Stale Files Problem (What v4 Solves)

When you bind-mount a host directory into a container, the host files persist across image updates. After `docker compose pull`, the new image has updated defaults but the old files on disk are still used. This affects:

| Directory | Source Image | What Goes Stale |
|-----------|-------------|-----------------|
| `emqx/etc/` | emqx:5 | EMQX config (can break on version bumps) |
| `gateway/conf/` | hummingbot/gateway | Chain configs, DEX connectors, token lists |
| `api/data/bots/controllers/` | hummingbot/hummingbot-api | Trading strategies |
| `api/data/bots/scripts/` | hummingbot/hummingbot-api | Example scripts |

v4 adds **version-aware init containers** that detect image changes and refresh these directories while preserving your edits.

---

## Init Container Architecture

All init containers run once, do their work, then exit. App containers wait for them via `depends_on: condition: service_completed_successfully`.

```
┌─────────────────────────────────┐
│  1. hummingbot-seed (emqx:5)    │  Creates all dirs, user-owned configs,
│     Runs: hummingbot_seed.sh    │  version-aware seeds EMQX /etc,
│     Uses: seed_helpers.sh       │  file mount guards
└──────────┬──────────────────────┘
           │ depends_on
    ┌──────┴──────┬───────────────────────┐
    │             │                       │
┌───┴────┐  ┌────┴─────┐  ┌──────────────┴──────┐
│ api-   │  │ gateway- │  │ password-init       │
│ init   │  │ init     │  │ (hummingbot:latest) │
│ (api   │  │ (gw      │  │                     │
│ image) │  │ image)   │  │ .password_          │
│        │  │          │  │ verification        │
│ docker_│  │ gateway/ │  └─────────────────────┘
│ service│  │ conf/    │
│ .py +  │  │ chains,  │
│ contrl │  │ tokens,  │
│ +scrpt │  │ pools    │
└────────┘  └──────────┘
           │
    ┌──────┴──────────────┐
    │  App containers     │
    │  (gluetun healthy)  │
    └─────────────────────┘
```

---

## What Gets Refreshed vs. What's Protected

### Never Overwritten (user-owned, created once)
- `hummingbot/conf/conf_client.yml`
- `dashboard/credentials.yml`
- `condor/config.yml`
- `condor/routines/*` (your custom routines)
- `controllers/mcp/*` (your MCP config)

### Version-Aware Refreshed (app-managed)
On image update: backs up → re-seeds from image → restores your edits.

- `emqx/etc/` — by hummingbot-seed
- `gateway/conf/` — by gateway-init
- `api/data/bots/controllers/` — by hummingbot-api-init
- `api/data/bots/scripts/` — by hummingbot-api-init
- `patches/docker_service.py` — by hummingbot-api-init

### Runtime Data (never touched by seed)
- `postgres/data/`, `emqx/data/`, all `logs/` directories
- `api/data/bots/instances/`, `api/data/bots/archived/`
- `gluetun/servers.json`

---

## Version Tracking Files

Each version-aware seeded directory contains:

- **`.seed_version`** — Image version when last seeded
- **`.seed_checksums`** — MD5 manifest of files as originally seeded

These let the system detect: (a) whether the image changed, and (b) which files you've edited since the last seed.

---

## Common Operations

### Normal Update
```bash
docker compose pull
docker compose up -d
# Init containers auto-detect version changes
```

### Force Re-Seed a Specific Directory
```bash
rm /mnt/sharedrive/apps/hummingbot/gateway/conf/.seed_version
docker compose up gateway-init
```

### Force Re-Extract docker_service.py
```bash
rm /mnt/sharedrive/apps/hummingbot/patches/docker_service.py
docker compose up hummingbot-api-init
```

---

## The docker_service.py Patch

The upstream `hummingbot-api` image hardcodes `network_mode="host"` when launching bot containers. This means bots spawned by the Dashboard/API **bypass the VPN entirely** and connect directly from your server's IP.

The patch adds two things:

1. **`_get_bot_network_mode()`** — Reads `DOCKER_BOT_NETWORK_MODE` env var (set to `container:gluetun` in compose) so bots share the VPN tunnel.

2. **`_get_compose_labels()`** — Tags spawned bots with Docker Compose labels so they appear in `docker compose ps`, Dozzle logs, and autoheal monitoring.

### How the Patch is Managed

- **First run** (fresh server): `api-init` auto-applies the patch via Python onto the upstream file. No manual work needed.
- **Same image version**: Does nothing. Your patched file stays.
- **Upstream image update**: Saves the new upstream as `.docker_service.py.upstream` and **warns you** with a big banner in the logs. Your patched file is never overwritten. You can then diff and decide whether to re-apply.
- **To re-apply on new upstream**: Delete the patched file and restart the init container:
  ```bash
  rm /mnt/sharedrive/apps/hummingbot/patches/docker_service.py
  docker compose up hummingbot-api-init
  ```

### Reference Files in patches/
| File | Purpose |
|------|---------|
| `docker_service.py` | Your active patched version (mounted read-only into hummingbot-api) |
| `.docker_service.py.upstream` | Latest upstream original (for diffing) |
| `.docker_service_upstream.md5` | Checksum to detect upstream changes |

### View Pre-Upgrade Backups
```bash
ls -d /mnt/sharedrive/apps/hummingbot/**/**.pre_upgrade_*
```

---

## Audit: Issues Found on Existing Server

These were found by cross-referencing the filesystem tree against the compose and seed script:

| Issue | Severity | Fix |
|-------|----------|-----|
| `api/docker_service.py` is a directory | 🔴 Rogue | cleanup.sh removes it |
| `hummingbot/conf/.password_verification` missing | 🔴 Missing | password-init creates it |
| `api/data/data/` nested duplicate | 🟡 Waste | cleanup.sh removes it |
| `gateway/conf/` never refreshed | 🟡 Stale | gateway-init now handles |
| `api/bots/controllers/` never refreshed | 🟡 Stale | api-init now handles |
| `api/bots/scripts/` never refreshed | 🟡 Stale | api-init now handles |
| `bootstrap/emqx-seed.sh` deprecated | 🟢 Cleanup | cleanup.sh removes it |
| `hummingbot/conf/conf_client.yml.bak` | 🟢 Cleanup | cleanup.sh removes it |

---

## NordVPN Credentials

| Variable | How to Get It |
|----------|--------------|
| `WIREGUARD_PRIVATE_KEY` | NordVPN dashboard → manual setup → Wireguard |
| `POSTGRES_PASSWORD` | `openssl rand -base64 24` |
| `GATEWAY_PASSPHRASE` | Any passphrase you choose |
| `TELEGRAM_TOKEN` | From @BotFather on Telegram |
| `ADMIN_USER_ID` | Your Telegram user ID (from @userinfobot) |
