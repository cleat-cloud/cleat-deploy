#!/usr/bin/env python3
"""First-party analytics sidecar: parse, HMAC uniques, HTML inject, SQLite store.

HTTP server is added in a later task; this module is importable functions + Store.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

SCRIPT_TAG = b'<script src="/cleat/a.js" defer></script>'
PATH_MAX = 512
UTM_MAX = 128
RAW_DAYS = 7
ROLLUP_DAYS = 90
DB_MAX_BYTES = 200 * 1024 * 1024
DB_TARGET_BYTES = 150 * 1024 * 1024

SCHEMA = """
CREATE TABLE IF NOT EXISTS hits (
  ts INTEGER NOT NULL,
  host TEXT NOT NULL,
  path TEXT NOT NULL,
  referrer TEXT NOT NULL DEFAULT '',
  utm_source TEXT NOT NULL DEFAULT '',
  utm_medium TEXT NOT NULL DEFAULT '',
  utm_campaign TEXT NOT NULL DEFAULT '',
  visitor_hash TEXT NOT NULL,
  name TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS hits_host_ts ON hits(host, ts);

CREATE TABLE IF NOT EXISTS daily_totals (
  day TEXT NOT NULL,
  host TEXT NOT NULL,
  pageviews INTEGER NOT NULL,
  unique_visitors INTEGER NOT NULL,
  PRIMARY KEY (day, host)
);

CREATE TABLE IF NOT EXISTS daily_paths (
  day TEXT NOT NULL,
  host TEXT NOT NULL,
  path TEXT NOT NULL,
  pageviews INTEGER NOT NULL,
  PRIMARY KEY (day, host, path)
);

CREATE TABLE IF NOT EXISTS daily_referrers (
  day TEXT NOT NULL,
  host TEXT NOT NULL,
  referrer TEXT NOT NULL,
  pageviews INTEGER NOT NULL,
  PRIMARY KEY (day, host, referrer)
);

CREATE TABLE IF NOT EXISTS daily_utm (
  day TEXT NOT NULL,
  host TEXT NOT NULL,
  utm_source TEXT NOT NULL,
  utm_medium TEXT NOT NULL,
  utm_campaign TEXT NOT NULL,
  pageviews INTEGER NOT NULL,
  PRIMARY KEY (day, host, utm_source, utm_medium, utm_campaign)
);
"""


def normalize_path(url):
    path = urlparse(url or "").path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/") or "/"
    if len(path) > PATH_MAX:
        path = path[:PATH_MAX]
    return path or "/"


def _utm_one(values):
    if not values:
        return ""
    value = values[0] or ""
    if not isinstance(value, str):
        value = str(value)
    return value[:UTM_MAX]


def utm_from(url):
    query = parse_qs(urlparse(url or "").query, keep_blank_values=False)
    return (
        _utm_one(query.get("utm_source")),
        _utm_one(query.get("utm_medium")),
        _utm_one(query.get("utm_campaign")),
    )


def normalize_referrer(referrer, host):
    if not referrer:
        return ""
    ref_host = urlparse(referrer).hostname or ""
    if not ref_host:
        return ""
    if host and ref_host.lower() == host.lower():
        return ""
    return ref_host


def visitor_hash(salt, ip, ua, host, day):
    message = f"{ip}\n{ua}\n{host}\n{day}".encode()
    return hmac.new(salt, message, hashlib.sha256).hexdigest()


def inject_html(html):
    if not isinstance(html, (bytes, bytearray)):
        return html
    raw = bytes(html)
    idx = raw.lower().rfind(b"</body>")
    if idx < 0:
        return raw
    return raw[:idx] + SCRIPT_TAG + raw[idx:]


def parse_event(*, host, payload, hosts, salt, ip, ua, day):
    if not host or host not in hosts:
        return None
    try:
        data = json.loads(payload)
    except (TypeError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict) or data.get("n") != "pageview":
        return None
    url = data.get("u") or ""
    referrer = data.get("r") or ""
    if not isinstance(url, str) or not isinstance(referrer, str):
        return None
    utm_source, utm_medium, utm_campaign = utm_from(url)
    return {
        "host": host,
        "path": normalize_path(url),
        "referrer": normalize_referrer(referrer, host),
        "utm_source": utm_source,
        "utm_medium": utm_medium,
        "utm_campaign": utm_campaign,
        "visitor_hash": visitor_hash(salt, ip, ua, host, day),
        "name": "pageview",
    }


class Store:
    def __init__(self, path):
        self.path = path
        self.conn = sqlite3.connect(path, timeout=5.0)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def insert_hit(
        self,
        ts,
        host,
        path,
        referrer,
        utm_source,
        utm_medium,
        utm_campaign,
        visitor_hash,
        name,
    ):
        self.conn.execute(
            """
            INSERT INTO hits (
              ts, host, path, referrer, utm_source, utm_medium, utm_campaign,
              visitor_hash, name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                int(ts),
                host,
                path,
                referrer or "",
                utm_source or "",
                utm_medium or "",
                utm_campaign or "",
                visitor_hash,
                name,
            ),
        )
        self.conn.commit()

    def count_hits(self):
        return self.conn.execute("SELECT COUNT(*) FROM hits").fetchone()[0]

    def count_daily_totals(self):
        return self.conn.execute("SELECT COUNT(*) FROM daily_totals").fetchone()[0]

    def rollup_and_prune(self, now_ts):
        now_ts = int(now_ts)
        self._rollup()
        raw_cutoff = now_ts - RAW_DAYS * 86400
        self.conn.execute("DELETE FROM hits WHERE ts < ?", (raw_cutoff,))
        rollup_day = (
            datetime.fromtimestamp(now_ts, tz=timezone.utc) - timedelta(days=ROLLUP_DAYS)
        ).strftime("%Y-%m-%d")
        for table in ("daily_totals", "daily_paths", "daily_referrers", "daily_utm"):
            self.conn.execute(f"DELETE FROM {table} WHERE day < ?", (rollup_day,))
        self.conn.commit()
        self._trim_if_oversized()

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def _rollup(self):
        self.conn.execute(
            """
            INSERT INTO daily_totals (day, host, pageviews, unique_visitors)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch') AS day,
                   host,
                   COUNT(*),
                   COUNT(DISTINCT visitor_hash)
            FROM hits
            WHERE name = 'pageview'
            GROUP BY day, host
            ON CONFLICT(day, host) DO UPDATE SET
              pageviews = excluded.pageviews,
              unique_visitors = excluded.unique_visitors
            """
        )
        self.conn.execute(
            """
            INSERT INTO daily_paths (day, host, path, pageviews)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch') AS day,
                   host,
                   path,
                   COUNT(*)
            FROM hits
            WHERE name = 'pageview'
            GROUP BY day, host, path
            ON CONFLICT(day, host, path) DO UPDATE SET
              pageviews = excluded.pageviews
            """
        )
        self.conn.execute(
            """
            INSERT INTO daily_referrers (day, host, referrer, pageviews)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch') AS day,
                   host,
                   referrer,
                   COUNT(*)
            FROM hits
            WHERE name = 'pageview'
            GROUP BY day, host, referrer
            ON CONFLICT(day, host, referrer) DO UPDATE SET
              pageviews = excluded.pageviews
            """
        )
        self.conn.execute(
            """
            INSERT INTO daily_utm (
              day, host, utm_source, utm_medium, utm_campaign, pageviews
            )
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch') AS day,
                   host,
                   utm_source,
                   utm_medium,
                   utm_campaign,
                   COUNT(*)
            FROM hits
            WHERE name = 'pageview'
            GROUP BY day, host, utm_source, utm_medium, utm_campaign
            ON CONFLICT(day, host, utm_source, utm_medium, utm_campaign) DO UPDATE SET
              pageviews = excluded.pageviews
            """
        )

    def _db_size(self):
        size = 0
        for suffix in ("", "-wal", "-shm"):
            path = self.path + suffix
            if os.path.exists(path):
                size += os.path.getsize(path)
        return size

    def _trim_if_oversized(self):
        if self._db_size() <= DB_MAX_BYTES:
            return
        while self._db_size() > DB_TARGET_BYTES:
            day = self.conn.execute(
                "SELECT MIN(strftime('%Y-%m-%d', ts, 'unixepoch')) FROM hits"
            ).fetchone()[0]
            if not day:
                break
            self.conn.execute(
                "DELETE FROM hits WHERE strftime('%Y-%m-%d', ts, 'unixepoch') = ?",
                (day,),
            )
            self.conn.commit()
            self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self.conn.execute("VACUUM")
