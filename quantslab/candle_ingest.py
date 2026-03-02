#!/usr/bin/env python3
"""
candle_ingest.py — Multi-exchange OHLCV candle ingestion for Quants Lab.

Pulls historical candle data from NonKYC, Binance, and MEXC public REST APIs,
then upserts into MongoDB.  Designed to run inside the Trading Pod (behind VPN)
on a recurring schedule via the candle-ingest Docker container.

Usage:
    python candle_ingest.py --config /app/config.yaml

MongoDB schema (collection: "candles"):
    {
        "connector":    "nonkyc",           # exchange identifier
        "trading_pair": "BTC-USDT",         # hummingbot-style pair (hyphen)
        "interval":     "1h",               # standardized interval string
        "timestamp":    1700000000,         # unix epoch seconds (UTC)
        "open":         97000.0,
        "high":         97500.0,
        "low":          96800.0,
        "close":        97200.0,
        "volume":       123.456
    }

    Compound unique index on (connector, trading_pair, interval, timestamp)
    ensures upserts are idempotent — safe to re-run without duplicates.
"""

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timezone
from typing import Any

import requests
import yaml
from pymongo import MongoClient, UpdateOne
from pymongo.errors import BulkWriteError

# ─── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("candle_ingest")

# ─── Constants ────────────────────────────────────────────────────────────────

COLLECTION_NAME = "candles"

# Max candles per API call (exchange-specific)
NONKYC_MAX_CANDLES = 500
BINANCE_MAX_CANDLES = 500
MEXC_MAX_CANDLES = 500

# Rate-limit courtesy delay between API calls (seconds)
REQUEST_DELAY = 1

# ─── Interval Mapping ────────────────────────────────────────────────────────
# Standardized interval string → exchange-specific parameter values
#
# None = exchange does not support this interval.
# The fetcher will skip and log a warning instead of returning wrong data.
#
# NonKYC minimum resolution is 5 minutes.  1m is NOT supported by NonKYC.

INTERVAL_MAP = {
    # standard   NonKYC (minutes)   Binance         MEXC
    "1m":       {"nonkyc": None,    "binance": "1m",    "mexc": "1m"},
    "5m":       {"nonkyc": 5,       "binance": "5m",    "mexc": "5m"},
    "15m":      {"nonkyc": 15,      "binance": "15m",   "mexc": "15m"},
    "30m":      {"nonkyc": 30,      "binance": "30m",   "mexc": "30m"},
    "1h":       {"nonkyc": 60,      "binance": "1h",    "mexc": "60m"},
    "3h":       {"nonkyc": 180,     "binance": "3h",    "mexc": "4h"},    # MEXC has no 3h, use 4h
    "4h":       {"nonkyc": 240,     "binance": "4h",    "mexc": "4h"},
    "8h":       {"nonkyc": 480,     "binance": "8h",    "mexc": "8h"},
    "12h":      {"nonkyc": 720,     "binance": "12h",   "mexc": "1d"},    # MEXC has no 12h
    "1d":       {"nonkyc": 1440,    "binance": "1d",    "mexc": "1d"},
}

# ─── Pair Format Helpers ─────────────────────────────────────────────────────

def to_hbot_pair(pair_str: str) -> str:
    """Normalize any pair format to hummingbot style: 'BTC-USDT'."""
    return pair_str.replace("/", "-").replace("_", "-").upper()


def to_nonkyc_symbol(hbot_pair: str) -> str:
    """BTC-USDT → BTC/USDT (NonKYC REST API format)."""
    base, quote = hbot_pair.split("-")
    return f"{base}/{quote}"


def to_binance_symbol(hbot_pair: str) -> str:
    """BTC-USDT → BTCUSDT (Binance format)."""
    return hbot_pair.replace("-", "")


def to_mexc_symbol(hbot_pair: str) -> str:
    """BTC-USDT → BTCUSDT (MEXC v3 format)."""
    return hbot_pair.replace("-", "")


# ─── Exchange Fetchers ────────────────────────────────────────────────────────

def fetch_nonkyc_candles(
    pair: str, interval: str, since_ts: int | None = None, limit: int = NONKYC_MAX_CANDLES
) -> list[dict]:
    """
    Fetch candles from NonKYC REST API.

    GET https://api.nonkyc.io/api/v2/market/candles
        ?symbol=BTC/USDT&resolution=60&countBack=500[&from=UNIX_S&to=UNIX_S]

    Response: { "bars": [{ "time": int, "open": float, "high": float,
                           "low": float, "close": float, "volume": float }] }
    """
    resolution = INTERVAL_MAP[interval]["nonkyc"]
    if resolution is None:
        log.warning("  NonKYC does not support %s interval — skipping", interval)
        return []

    symbol = to_nonkyc_symbol(pair)

    params: dict[str, Any] = {
        "symbol": symbol,
        "resolution": resolution,
        "countBack": min(limit, NONKYC_MAX_CANDLES),
        "firstDataRequest": 1 if since_ts is None else 0,
    }
    if since_ts is not None:
        params["from"] = since_ts

    url = "https://api.nonkyc.io/api/v2/market/candles"
    resp = requests.get(url, params=params, timeout=30)
    resp.raise_for_status()

    data = resp.json()
    bars = data.get("bars", [])

    candles = []
    for bar in bars:
        candles.append({
            "connector": "nonkyc",
            "trading_pair": pair,
            "interval": interval,
            "timestamp": int(bar["time"]),
            "open": float(bar["open"]),
            "high": float(bar["high"]),
            "low": float(bar["low"]),
            "close": float(bar["close"]),
            "volume": float(bar["volume"]),
        })
    return candles


def fetch_binance_candles(
    pair: str, interval: str, since_ts: int | None = None, limit: int = BINANCE_MAX_CANDLES
) -> list[dict]:
    """
    Fetch candles from Binance public API.

    GET https://api.binance.com/api/v3/klines
        ?symbol=BTCUSDT&interval=1h&limit=500[&startTime=UNIX_MS]

    Response: list of lists [open_time, open, high, low, close, volume, ...]
    """
    bi_interval = INTERVAL_MAP[interval]["binance"]
    if bi_interval is None:
        log.warning("  Binance does not support %s interval — skipping", interval)
        return []

    symbol = to_binance_symbol(pair)

    params: dict[str, Any] = {
        "symbol": symbol,
        "interval": bi_interval,
        "limit": min(limit, BINANCE_MAX_CANDLES),
    }
    if since_ts is not None:
        params["startTime"] = since_ts * 1000  # Binance uses milliseconds

    url = "https://api.binance.com/api/v3/klines"
    resp = requests.get(url, params=params, timeout=30)
    resp.raise_for_status()

    data = resp.json()
    candles = []
    for k in data:
        candles.append({
            "connector": "binance",
            "trading_pair": pair,
            "interval": interval,
            "timestamp": int(k[0]) // 1000,  # ms → seconds
            "open": float(k[1]),
            "high": float(k[2]),
            "low": float(k[3]),
            "close": float(k[4]),
            "volume": float(k[5]),
        })
    return candles


def fetch_mexc_candles(
    pair: str, interval: str, since_ts: int | None = None, limit: int = MEXC_MAX_CANDLES
) -> list[dict]:
    """
    Fetch candles from MEXC v3 public API.

    GET https://api.mexc.com/api/v3/klines
        ?symbol=BTCUSDT&interval=1h&limit=500[&startTime=UNIX_MS]

    Response: list of lists [open_time, open, high, low, close, volume, ...]
    """
    mx_interval = INTERVAL_MAP[interval]["mexc"]
    if mx_interval is None:
        log.warning("  MEXC does not support %s interval — skipping", interval)
        return []

    symbol = to_mexc_symbol(pair)

    params: dict[str, Any] = {
        "symbol": symbol,
        "interval": mx_interval,
        "limit": min(limit, MEXC_MAX_CANDLES),
    }
    if since_ts is not None:
        params["startTime"] = since_ts * 1000

    url = "https://api.mexc.com/api/v3/klines"
    resp = requests.get(url, params=params, timeout=30)
    resp.raise_for_status()

    data = resp.json()
    candles = []
    for k in data:
        candles.append({
            "connector": "mexc",
            "trading_pair": pair,
            "interval": interval,
            "timestamp": int(k[0]) // 1000,
            "open": float(k[1]),
            "high": float(k[2]),
            "low": float(k[3]),
            "close": float(k[4]),
            "volume": float(k[5]),
        })
    return candles


# ─── Fetcher Dispatch ─────────────────────────────────────────────────────────

FETCHERS = {
    "nonkyc": fetch_nonkyc_candles,
    "binance": fetch_binance_candles,
    "mexc": fetch_mexc_candles,
}

# ─── MongoDB ──────────────────────────────────────────────────────────────────

def get_mongo_collection(mongo_uri: str, db_name: str):
    """Connect to MongoDB and return the candles collection with indexes."""
    client = MongoClient(mongo_uri, serverSelectionTimeoutMS=10000)
    # Verify connectivity
    client.admin.command("ping")
    db = client[db_name]
    coll = db[COLLECTION_NAME]

    # Create compound unique index (idempotent — no-op if exists)
    coll.create_index(
        [("connector", 1), ("trading_pair", 1), ("interval", 1), ("timestamp", 1)],
        unique=True,
        name="idx_connector_pair_interval_ts",
    )
    # Useful for "give me latest timestamp" queries
    coll.create_index(
        [("connector", 1), ("trading_pair", 1), ("interval", 1), ("timestamp", -1)],
        name="idx_latest_ts",
    )
    return coll


def upsert_candles(coll, candles: list[dict]) -> int:
    """Bulk upsert candles into MongoDB.  Returns count of modified/inserted docs."""
    if not candles:
        return 0

    ops = []
    for c in candles:
        filt = {
            "connector": c["connector"],
            "trading_pair": c["trading_pair"],
            "interval": c["interval"],
            "timestamp": c["timestamp"],
        }
        ops.append(UpdateOne(filt, {"$set": c}, upsert=True))

    try:
        result = coll.bulk_write(ops, ordered=False)
        return result.upserted_count + result.modified_count
    except BulkWriteError as e:
        # Duplicate key errors are expected and harmless with upserts
        log.warning("BulkWriteError (likely harmless dupes): %s", e.details.get("writeErrors", [])[:3])
        return e.details.get("nInserted", 0) + e.details.get("nModified", 0)


def get_latest_timestamp(coll, connector: str, pair: str, interval: str) -> int | None:
    """Return the most recent timestamp for this connector/pair/interval, or None."""
    doc = coll.find_one(
        {"connector": connector, "trading_pair": pair, "interval": interval},
        sort=[("timestamp", -1)],
        projection={"timestamp": 1},
    )
    return doc["timestamp"] if doc else None


# ─── Ingestion Logic ─────────────────────────────────────────────────────────

def ingest_pair(
    coll,
    connector: str,
    pair: str,
    interval: str,
    backfill_days: int = 90,
) -> int:
    """
    Ingest candles for one connector/pair/interval combo.

    On first run: backfills `backfill_days` of history.
    On subsequent runs: fetches from the last known timestamp forward.
    """
    hbot_pair = to_hbot_pair(pair)
    fetcher = FETCHERS.get(connector)
    if fetcher is None:
        log.error("No fetcher for connector '%s' — skipping %s %s", connector, pair, interval)
        return 0

    # Pre-check: does this connector support the requested interval?
    interval_cfg = INTERVAL_MAP.get(interval, {})
    if interval_cfg.get(connector) is None:
        log.info("  %s does not support %s — skipping %s", connector, interval, hbot_pair)
        return 0

    # Check how far back we already have data
    latest_ts = get_latest_timestamp(coll, connector, hbot_pair, interval)

    if latest_ts is not None:
        # Incremental: start from the last candle we have
        since_ts = latest_ts
        log.info(
            "  Incremental update: %s %s %s from %s",
            connector, hbot_pair, interval,
            datetime.fromtimestamp(since_ts, tz=timezone.utc).isoformat(),
        )
    else:
        # Backfill: go back N days
        since_ts = int(time.time()) - (backfill_days * 86400)
        log.info(
            "  Backfill %dd: %s %s %s from %s",
            backfill_days, connector, hbot_pair, interval,
            datetime.fromtimestamp(since_ts, tz=timezone.utc).isoformat(),
        )

    total_upserted = 0
    page_since = since_ts

    # Paginate until we catch up to now
    while True:
        try:
            candles = fetcher(hbot_pair, interval, since_ts=page_since)
        except requests.RequestException as e:
            log.error("  API error for %s %s %s: %s", connector, hbot_pair, interval, e)
            break

        if not candles:
            break

        count = upsert_candles(coll, candles)
        total_upserted += count

        # Advance the cursor to the last timestamp we received
        last_ts = max(c["timestamp"] for c in candles)
        if last_ts <= page_since:
            # No progress — we've caught up
            break
        page_since = last_ts

        log.info(
            "    Fetched %d candles (%d upserted), latest: %s",
            len(candles), count,
            datetime.fromtimestamp(last_ts, tz=timezone.utc).isoformat(),
        )

        # Rate-limit courtesy
        time.sleep(REQUEST_DELAY)

        # If we got fewer than a full page, we've reached the end
        if len(candles) < 500:
            break

    return total_upserted


# ─── Config Loading ───────────────────────────────────────────────────────────

def load_config(path: str) -> dict:
    """Load the YAML config file."""
    with open(path) as f:
        return yaml.safe_load(f)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Multi-exchange candle ingestion for Quants Lab")
    parser.add_argument("--config", default="/app/config.yaml", help="Path to config YAML")
    args = parser.parse_args()

    # MongoDB connection
    mongo_uri = os.environ.get("MONGO_URI", "mongodb://admin:admin@127.0.0.1:27017/quants_lab?authSource=admin")
    db_name = os.environ.get("MONGO_DATABASE", "quants_lab")

    log.info("Connecting to MongoDB: %s (db: %s)", mongo_uri.split("@")[-1], db_name)
    try:
        coll = get_mongo_collection(mongo_uri, db_name)
    except Exception as e:
        log.error("Failed to connect to MongoDB: %s", e)
        sys.exit(1)
    log.info("MongoDB connected.  Collection: %s", COLLECTION_NAME)

    # Load config
    config = load_config(args.config)
    backfill_days = config.get("backfill_days", 90)

    exchanges = config.get("exchanges", {})
    if not exchanges:
        log.warning("No exchanges configured — nothing to ingest.")
        return

    # Run ingestion for each exchange → pair → interval
    grand_total = 0
    for connector, exc_cfg in exchanges.items():
        pairs = exc_cfg.get("pairs", [])
        intervals = exc_cfg.get("intervals", ["1h"])
        enabled = exc_cfg.get("enabled", True)

        if not enabled:
            log.info("Skipping disabled connector: %s", connector)
            continue

        log.info("━━━ %s: %d pairs × %d intervals ━━━", connector.upper(), len(pairs), len(intervals))

        for pair in pairs:
            for interval in intervals:
                if interval not in INTERVAL_MAP:
                    log.warning("  Unknown interval '%s' — skipping", interval)
                    continue
                try:
                    count = ingest_pair(coll, connector, pair, interval, backfill_days)
                    grand_total += count
                except Exception as e:
                    log.error("  Unexpected error on %s %s %s: %s", connector, pair, interval, e)

    log.info("═══ Ingestion complete: %d total candles upserted ═══", grand_total)


if __name__ == "__main__":
    main()
