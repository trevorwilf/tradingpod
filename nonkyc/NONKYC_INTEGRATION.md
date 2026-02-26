# Adding NonKYC to Your Trading Pod

## What This Does

The `build_hummingbot_nonkyc.sh` script creates a custom Docker image that is:
- **100% official hummingbot** (latest `master` branch)
- **Plus** the `nonkyc` exchange connector from `NonKYCExchange/hummingbot`

No other changes. All other Trading Pod services (API, Gateway, Dashboard, MCP, Condor) continue using their official images unchanged.

## Quick Start

```bash
# 1. Run the build (first time takes ~10-15 min)
chmod +x build_hummingbot_nonkyc.sh
./build_hummingbot_nonkyc.sh

# 2. Edit your compose file — change ONE line:
#    image: hummingbot/hummingbot:latest
#    →
#    image: hummingbot-nonkyc:latest
```

## Compose Change

In `hummingbot_App_v2.yaml`, find the `hummingbot:` service and change only the image:

```yaml
  hummingbot:
    # BEFORE:
    # image: hummingbot/hummingbot:latest
    # AFTER:
    image: hummingbot-nonkyc:latest
    container_name: hummingbot
    # ... everything else stays exactly the same
```

**Do NOT change** the image for any other service. Only `hummingbot:` needs the custom image.

## Updating

When you want to pick up new releases from either upstream:

```bash
# Re-run the build — it pulls the latest from both repos
./build_hummingbot_nonkyc.sh

# Then restart the pod
docker compose down hummingbot
docker compose up -d hummingbot
```

## How It Works

Hummingbot connectors are self-contained Python modules in `hummingbot/connector/exchange/<name>/`. Each connector folder contains:

| File | Purpose |
|------|---------|
| `__init__.py` | Module init |
| `nonkyc_exchange.py` | Main exchange class (order management, balances) |
| `nonkyc_api_order_book_data_source.py` | WebSocket + REST order book feeds |
| `nonkyc_auth.py` | API key authentication |
| `nonkyc_web_utils.py` | HTTP helpers, rate limiting |
| `nonkyc_utils.py` | Connector config — exports `KEYS` for auto-registration |
| `nonkyc_constants.py` | API endpoints, constants |

The `_utils.py` file's `KEYS` export is how Hummingbot auto-discovers connectors — no central registry to edit. Drop the folder in, and the connector appears in `connect` and strategy configs.

## Troubleshooting

**Build fails on Dockerfile?**
The official Dockerfile uses conda. Make sure Docker has enough memory (~4GB) and disk (~10GB).

**Connector not showing up in `connect` command?**
Check the container logs for import errors:
```bash
docker compose logs hummingbot 2>&1 | grep -i nonkyc
```

**API/Dashboard don't see the NonKYC connector?**
The API spawns bot containers using the `DOCKER_BOT_NETWORK_MODE` env var. Make sure spawned bots also use your custom image. In the compose, the `hummingbot-api` service has `BOTS_PATH` which controls the image for spawned bots — check that it picks up the custom image.
