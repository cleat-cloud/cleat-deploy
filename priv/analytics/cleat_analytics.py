#!/usr/bin/env python3
"""First-party analytics sidecar: parse, HMAC uniques, HTML inject, SQLite store, HTTP collect."""

from __future__ import annotations

import hashlib
import hmac
import http.client
import json
import os
import sqlite3
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

SCRIPT_TAG = b'<script src="/cleat/a.js" defer></script>'
SCRIPT_JS = (
    b'(()=>{try{var b=new Blob([JSON.stringify({n:"pageview",u:location.href,r:document.referrer||""})],'
    b'{type:"text/plain"});navigator.sendBeacon("/cleat/a",b);}catch(e){}})();'
)
PATH_MAX = 512
UTM_MAX = 128
RAW_DAYS = 7
ROLLUP_DAYS = 90
MAX_BODY = 8 * 1024
DEFAULT_PORT = 8799
DEFAULT_DB = "/var/lib/cleat-analytics/analytics.db"
DEFAULT_HOSTS = "/etc/cleat/analytics-hosts.json"
DEFAULT_SALT = "/etc/cleat/analytics.salt"
DB_MAX_BYTES = 200 * 1024 * 1024
DB_TARGET_BYTES = 150 * 1024 * 1024
ROLLUP_INTERVAL = 3600
HTML_MAX = 1024 * 1024
PROXY_TIMEOUT = 2.0
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)

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


def canonical_host(host):
    if not host:
        return ""
    host = host.strip()
    if host.startswith("["):
        end = host.find("]")
        if end != -1:
            host = host[1:end]
        return host.lower()
    if ":" in host:
        name, port = host.rsplit(":", 1)
        if port.isdigit():
            host = name
    return host.lower()


def resolve_host(host, hosts):
    key = canonical_host(host)
    if not key or not hosts:
        return None
    folded = {canonical_host(name): name for name in hosts}
    return folded.get(key)


def parse_event(*, host, payload, hosts, salt, ip, ua, day):
    resolved = resolve_host(host, hosts)
    if not resolved:
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
        "host": resolved,
        "path": normalize_path(url),
        "referrer": normalize_referrer(referrer, resolved),
        "utm_source": utm_source,
        "utm_medium": utm_medium,
        "utm_campaign": utm_campaign,
        "visitor_hash": visitor_hash(salt, ip, ua, resolved, day),
        "name": "pageview",
    }


class Store:
    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()
        self.conn = sqlite3.connect(path, timeout=5.0, check_same_thread=False)
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
        with self._lock:
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
        with self._lock:
            return self.conn.execute("SELECT COUNT(*) FROM hits").fetchone()[0]

    def count_daily_totals(self):
        with self._lock:
            return self.conn.execute("SELECT COUNT(*) FROM daily_totals").fetchone()[0]

    def visited(self, now_ts, range_key, hosts, limit=20):
        hosts = hosts or {}
        if range_key == "90d":
            start_day = _day_ago(now_ts, 90)
            with self._lock:
                rows = self.conn.execute(
                    """
                    SELECT host, SUM(pageviews) AS pageviews
                    FROM daily_totals
                    WHERE day >= ?
                    GROUP BY host
                    ORDER BY pageviews DESC
                    LIMIT ?
                    """,
                    (start_day, limit),
                ).fetchall()
        else:
            since = int(now_ts) - _range_seconds(range_key)
            with self._lock:
                rows = self.conn.execute(
                    """
                    SELECT host, COUNT(*) AS pageviews
                    FROM hits
                    WHERE name = 'pageview' AND ts >= ?
                    GROUP BY host
                    ORDER BY pageviews DESC
                    LIMIT ?
                    """,
                    (since, limit),
                ).fetchall()
        out = []
        for host, pageviews in rows:
            resolved = resolve_host(host, hosts) or host
            info = hosts.get(resolved) or hosts.get(host) or {}
            slug = info.get("slug") if isinstance(info, dict) else ""
            out.append(
                {
                    "host": host,
                    "slug": slug or "",
                    "pageviews": int(pageviews or 0),
                }
            )
        return out

    def app_summary(self, host, range_key, now_ts, hosts=None):
        resolved = resolve_host(host, hosts or {}) or canonical_host(host) or host
        if range_key == "90d":
            return self._app_summary_rollup(resolved, now_ts)
        since = int(now_ts) - _range_seconds(range_key)
        hourly = range_key != "7d"
        with self._lock:
            pageviews, uniques = self.conn.execute(
                """
                SELECT COUNT(*), COUNT(DISTINCT visitor_hash)
                FROM hits
                WHERE name = 'pageview' AND host = ? AND ts >= ?
                """,
                (resolved, since),
            ).fetchone()
            if hourly:
                series_sql = """
                    SELECT strftime('%Y-%m-%dT%H:00:00Z', ts, 'unixepoch') AS bucket,
                           COUNT(*)
                    FROM hits
                    WHERE name = 'pageview' AND host = ? AND ts >= ?
                    GROUP BY bucket
                    ORDER BY bucket
                """
            else:
                series_sql = """
                    SELECT strftime('%Y-%m-%d', ts, 'unixepoch') AS bucket, COUNT(*)
                    FROM hits
                    WHERE name = 'pageview' AND host = ? AND ts >= ?
                    GROUP BY bucket
                    ORDER BY bucket
                """
            series = [
                {"t": bucket, "pageviews": int(n)}
                for bucket, n in self.conn.execute(series_sql, (resolved, since))
            ]
            paths = [
                {"path": path, "pageviews": int(n)}
                for path, n in self.conn.execute(
                    """
                    SELECT path, COUNT(*)
                    FROM hits
                    WHERE name = 'pageview' AND host = ? AND ts >= ?
                    GROUP BY path
                    ORDER BY COUNT(*) DESC
                    LIMIT 20
                    """,
                    (resolved, since),
                )
            ]
            referrers = [
                {"referrer": ref, "pageviews": int(n)}
                for ref, n in self.conn.execute(
                    """
                    SELECT referrer, COUNT(*)
                    FROM hits
                    WHERE name = 'pageview' AND host = ? AND ts >= ?
                    GROUP BY referrer
                    ORDER BY COUNT(*) DESC
                    LIMIT 20
                    """,
                    (resolved, since),
                )
            ]
            utm = [
                _utm_json(source, medium, campaign, n)
                for source, medium, campaign, n in self.conn.execute(
                    """
                    SELECT utm_source, utm_medium, utm_campaign, COUNT(*)
                    FROM hits
                    WHERE name = 'pageview' AND host = ? AND ts >= ?
                    GROUP BY utm_source, utm_medium, utm_campaign
                    ORDER BY COUNT(*) DESC
                    LIMIT 20
                    """,
                    (resolved, since),
                )
            ]
        return {
            "pageviews": int(pageviews or 0),
            "uniques": int(uniques or 0),
            "series": series,
            "paths": paths,
            "referrers": referrers,
            "utm": utm,
        }

    def _app_summary_rollup(self, host, now_ts):
        start_day = _day_ago(now_ts, 90)
        with self._lock:
            pageviews, uniques = self.conn.execute(
                """
                SELECT COALESCE(SUM(pageviews), 0), COALESCE(SUM(unique_visitors), 0)
                FROM daily_totals
                WHERE host = ? AND day >= ?
                """,
                (host, start_day),
            ).fetchone()
            series = [
                {"t": day, "pageviews": int(n)}
                for day, n in self.conn.execute(
                    """
                    SELECT day, pageviews
                    FROM daily_totals
                    WHERE host = ? AND day >= ?
                    ORDER BY day
                    """,
                    (host, start_day),
                )
            ]
            paths = [
                {"path": path, "pageviews": int(n)}
                for path, n in self.conn.execute(
                    """
                    SELECT path, SUM(pageviews)
                    FROM daily_paths
                    WHERE host = ? AND day >= ?
                    GROUP BY path
                    ORDER BY SUM(pageviews) DESC
                    LIMIT 20
                    """,
                    (host, start_day),
                )
            ]
            referrers = [
                {"referrer": ref, "pageviews": int(n)}
                for ref, n in self.conn.execute(
                    """
                    SELECT referrer, SUM(pageviews)
                    FROM daily_referrers
                    WHERE host = ? AND day >= ?
                    GROUP BY referrer
                    ORDER BY SUM(pageviews) DESC
                    LIMIT 20
                    """,
                    (host, start_day),
                )
            ]
            utm = [
                _utm_json(source, medium, campaign, n)
                for source, medium, campaign, n in self.conn.execute(
                    """
                    SELECT utm_source, utm_medium, utm_campaign, SUM(pageviews)
                    FROM daily_utm
                    WHERE host = ? AND day >= ?
                    GROUP BY utm_source, utm_medium, utm_campaign
                    ORDER BY SUM(pageviews) DESC
                    LIMIT 20
                    """,
                    (host, start_day),
                )
            ]
        return {
            "pageviews": int(pageviews or 0),
            "uniques": int(uniques or 0),
            "series": series,
            "paths": paths,
            "referrers": referrers,
            "utm": utm,
        }

    def rollup_and_prune(self, now_ts):
        now_ts = int(now_ts)
        with self._lock:
            self._rollup(now_ts)
            raw_cutoff = now_ts - RAW_DAYS * 86400
            self.conn.execute("DELETE FROM hits WHERE ts < ?", (raw_cutoff,))
            rollup_day = (
                datetime.fromtimestamp(now_ts, tz=timezone.utc)
                - timedelta(days=ROLLUP_DAYS)
            ).strftime("%Y-%m-%d")
            for table in ("daily_totals", "daily_paths", "daily_referrers", "daily_utm"):
                self.conn.execute(f"DELETE FROM {table} WHERE day < ?", (rollup_day,))
            self.conn.commit()
            self._trim_if_oversized()

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def _fresh_day(self, now_ts):
        cutoff = datetime.fromtimestamp(
            now_ts - RAW_DAYS * 86400, tz=timezone.utc
        )
        return cutoff.strftime("%Y-%m-%d")

    def _rollup(self, now_ts):
        # Refresh only days fully inside the raw window (day > date(now-7d)).
        # Older days: insert-if-missing, never update (a split UTC day would
        # otherwise clobber 90d totals with the remaining partial raw count).
        fresh_after = self._fresh_day(now_ts)
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
            WHERE excluded.day > ?
            """,
            (fresh_after,),
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
            WHERE excluded.day > ?
            """,
            (fresh_after,),
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
            WHERE excluded.day > ?
            """,
            (fresh_after,),
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
            WHERE excluded.day > ?
            """,
            (fresh_after,),
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


def _utm_json(source, medium, campaign, n):
    return {
        "source": source,
        "medium": medium,
        "campaign": campaign,
        "pageviews": int(n),
    }


def _range_seconds(range_key):
    if range_key == "7d":
        return 7 * 86400
    if range_key == "90d":
        return 90 * 86400
    return 86400


def _day_ago(now_ts, days):
    return (
        datetime.fromtimestamp(int(now_ts), tz=timezone.utc) - timedelta(days=days)
    ).strftime("%Y-%m-%d")


def _query_range(query):
    values = parse_qs(query).get("range") or ["24h"]
    key = values[0]
    if key not in ("24h", "7d", "90d"):
        return "24h"
    return key


def load_hosts(path, previous=None):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return data
    except (OSError, TypeError, ValueError):
        pass
    if previous is not None:
        return previous
    return {}


def split_upstream(upstream):
    raw = (upstream or "").strip()
    if not raw:
        return None
    if raw.startswith("http://") or raw.startswith("https://"):
        parsed = urlparse(raw)
        if not parsed.hostname:
            return None
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        return parsed.hostname, port
    if raw.startswith("["):
        end = raw.find("]")
        if end == -1:
            return None
        host = raw[1:end]
        rest = raw[end + 1 :]
        if rest.startswith(":") and rest[1:].isdigit():
            return host, int(rest[1:])
        return host, 80
    if ":" in raw:
        host, port_s = raw.rsplit(":", 1)
        if not port_s.isdigit():
            return None
        return host, int(port_s)
    return raw, 80


def load_salt(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


def default_db_path():
    env = os.environ.get("CLEAT_ANALYTICS_DB")
    if env:
        return env
    state = os.environ.get("STATE_DIRECTORY")
    if state:
        return os.path.join(state.split(":")[0], "analytics.db")
    return DEFAULT_DB


def _rollup_loop(store, stop_event):
    while not stop_event.wait(ROLLUP_INTERVAL):
        try:
            store.rollup_and_prune(now_ts=int(time.time()))
        except Exception as exc:
            sys.stderr.write(f"cleat-analytics rollup failed: {exc}\n")


class AnalyticsServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


class AnalyticsHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def _hosts(self):
        previous = getattr(self.server, "hosts", None)
        hosts = load_hosts(self.server.hosts_path, previous)
        self.server.hosts = hosts
        return hosts

    def _salt(self):
        salt = load_salt(self.server.salt_path)
        return salt or self.server.salt

    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0]

    def _read_body(self, limit=MAX_BODY):
        length_hdr = self.headers.get("Content-Length")
        if length_hdr is None:
            data = self.rfile.read(limit + 1)
            if len(data) > limit:
                return None
            return data
        try:
            length = int(length_hdr)
        except ValueError:
            return None
        if length < 0:
            return None
        if length > limit:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
            return None
        return self.rfile.read(length)

    def _send(self, status, body=b"", content_type="text/plain", extra=None):
        if not isinstance(body, (bytes, bytearray)):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()
        if status != 204 and self.command != "HEAD":
            self.wfile.write(body)

    def _send_204(self):
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_json(self, payload):
        self._send(200, json.dumps(payload).encode(), "application/json")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/healthz":
            self._send(200, b"ok")
            return
        if path == "/cleat/a.js":
            self._send(
                200,
                SCRIPT_JS,
                "application/javascript",
                extra={"Cache-Control": "public, max-age=3600"},
            )
            return
        if path == "/v1/visited":
            try:
                hosts = self._hosts()
                payload = self.server.store.visited(
                    now_ts=int(time.time()),
                    range_key=_query_range(parsed.query),
                    hosts=hosts,
                )
                self._send_json(payload)
            except Exception:
                self._send_json([])
            return
        if path.startswith("/v1/apps/"):
            host = unquote(path[len("/v1/apps/") :])
            try:
                hosts = self._hosts()
                payload = self.server.store.app_summary(
                    host=host,
                    range_key=_query_range(parsed.query),
                    now_ts=int(time.time()),
                    hosts=hosts,
                )
                self._send_json(payload)
            except Exception:
                self._send_json(
                    {
                        "pageviews": 0,
                        "uniques": 0,
                        "series": [],
                        "paths": [],
                        "referrers": [],
                        "utm": [],
                    }
                )
            return
        self._proxy()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/cleat/a":
            try:
                body = self._read_body()
            except Exception:
                self._send_204()
                return
            try:
                if body is not None:
                    hosts = self._hosts()
                    salt = self._salt()
                    now = datetime.now(timezone.utc)
                    row = parse_event(
                        host=self.headers.get("Host"),
                        payload=body,
                        hosts=hosts,
                        salt=salt,
                        ip=self._client_ip(),
                        ua=self.headers.get("User-Agent") or "",
                        day=now.strftime("%Y-%m-%d"),
                    )
                    if row:
                        self.server.store.insert_hit(ts=int(now.timestamp()), **row)
            except Exception:
                pass
            self._send_204()
            return
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def _proxy(self):
        hosts = self._hosts()
        resolved = resolve_host(self.headers.get("Host"), hosts)
        info = hosts.get(resolved) if resolved else None
        target = split_upstream((info or {}).get("upstream") if isinstance(info, dict) else "")
        if not target:
            self._send(502, b"")
            return
        host, port = target
        try:
            body = None
            if self.command not in ("GET", "HEAD"):
                body = self._read_proxy_body()
            headers = {}
            for key, value in self.headers.items():
                if key.lower() in HOP_BY_HOP:
                    continue
                headers[key] = value
            conn = http.client.HTTPConnection(host, port, timeout=PROXY_TIMEOUT)
            try:
                conn.request(self.command, self.path, body=body, headers=headers)
                self._relay(conn.getresponse())
            finally:
                conn.close()
        except Exception:
            try:
                self._send(502, b"")
            except Exception:
                pass

    def _read_proxy_body(self):
        length_hdr = self.headers.get("Content-Length")
        if not length_hdr:
            return b""
        try:
            length = int(length_hdr)
        except ValueError:
            return b""
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _relay(self, resp):
        content_type = (resp.getheader("Content-Type") or "").lower()
        filtered = [
            (key, value)
            for key, value in resp.getheaders()
            if key.lower() not in HOP_BY_HOP
        ]
        if content_type.startswith("text/html"):
            data = resp.read(HTML_MAX + 1)
            if len(data) <= HTML_MAX:
                data = inject_html(data)
            else:
                data = data + resp.read()
            self.send_response(resp.status, resp.reason)
            for key, value in filtered:
                if key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        self.send_response(resp.status, resp.reason)
        has_length = False
        for key, value in filtered:
            if key.lower() == "content-length":
                has_length = True
            self.send_header(key, value)
        if not has_length:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command == "HEAD":
            return
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            self.wfile.write(chunk)


def make_httpd():
    port = int(os.environ.get("CLEAT_ANALYTICS_PORT") or DEFAULT_PORT)
    db_path = default_db_path()
    hosts_path = os.environ.get("CLEAT_ANALYTICS_HOSTS") or DEFAULT_HOSTS
    salt_path = os.environ.get("CLEAT_ANALYTICS_SALT") or DEFAULT_SALT
    salt = load_salt(salt_path)
    if not salt:
        raise SystemExit("cleat-analytics salt missing")
    parent = os.path.dirname(db_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    store = Store(db_path)
    httpd = AnalyticsServer(("127.0.0.1", port), AnalyticsHandler)
    httpd.store = store
    httpd.hosts_path = hosts_path
    httpd.hosts = load_hosts(hosts_path)
    httpd.salt_path = salt_path
    httpd.salt = salt
    httpd.stop_event = threading.Event()
    httpd.rollup_thread = threading.Thread(
        target=_rollup_loop, args=(store, httpd.stop_event), daemon=True
    )
    httpd.rollup_thread.start()
    return httpd


def main():
    httpd = make_httpd()
    try:
        httpd.serve_forever()
    finally:
        stop = getattr(httpd, "stop_event", None)
        if stop is not None:
            stop.set()
        httpd.server_close()
        store = getattr(httpd, "store", None)
        if store is not None:
            store.close()


if __name__ == "__main__":
    main()

