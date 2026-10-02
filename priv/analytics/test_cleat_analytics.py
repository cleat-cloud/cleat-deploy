import contextlib
import hashlib
import hmac
import io
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timezone

import cleat_analytics as ca


HOSTS = {
    "nfe.gestaobem.com": {"slug": "nfe-facil", "upstream": "127.0.0.1:4033"}
}


class ParseTest(unittest.TestCase):
    def test_path_strips_query_and_slash(self):
        self.assertEqual(ca.normalize_path("https://nfe.gestaobem.com/login/?x=1"), "/login")
        self.assertEqual(ca.normalize_path("https://nfe.gestaobem.com"), "/")

    def test_utm(self):
        u, m, c = ca.utm_from("https://x.com/?utm_source=google&utm_medium=cpc&utm_campaign=a&foo=1")
        self.assertEqual((u, m, c), ("google", "cpc", "a"))

    def test_referrer_empty_when_same_host(self):
        self.assertEqual(ca.normalize_referrer("https://nfe.gestaobem.com/x", "nfe.gestaobem.com"), "")
        self.assertEqual(ca.normalize_referrer("https://google.com/q", "nfe.gestaobem.com"), "google.com")

    def test_visitor_hash_stable(self):
        salt = b"x" * 32
        a = ca.visitor_hash(salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-01")
        b = ca.visitor_hash(salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-01")
        c = ca.visitor_hash(salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-02")
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)
        self.assertEqual(len(a), 64)
        expected = hmac.new(
            salt, b"1.1.1.1\nua\nnfe.gestaobem.com\n2026-10-01", hashlib.sha256
        ).hexdigest()
        self.assertEqual(a, expected)

    def test_inject_before_body(self):
        html = b"<html><body>hi</body></html>"
        out = ca.inject_html(html)
        self.assertIn(b'<script src="/cleat/a.js" defer></script></body>', out)

    def test_inject_skips_without_body(self):
        raw = b'{"ok":true}'
        self.assertEqual(ca.inject_html(raw), raw)

    def test_inject_uppercase_body(self):
        html = b"<HTML><BODY>hi</BODY></HTML>"
        out = ca.inject_html(html)
        self.assertIn(b'<script src="/cleat/a.js" defer></script></BODY>', out)

    def test_unknown_host_dropped(self):
        row = ca.parse_event(
            host="nope.example",
            payload=b'{"n":"pageview","u":"https://nope.example/","r":""}',
            hosts={},
            salt=b"x" * 32,
            ip="1.1.1.1",
            ua="ua",
            day="2026-10-01",
        )
        self.assertIsNone(row)

    def test_rejects_non_pageview(self):
        row = ca.parse_event(
            host="nfe.gestaobem.com",
            payload=b'{"n":"click","u":"https://nfe.gestaobem.com/","r":""}',
            hosts=HOSTS,
            salt=b"x" * 32,
            ip="1.1.1.1",
            ua="ua",
            day="2026-10-01",
        )
        self.assertIsNone(row)

    def test_invalid_json_dropped(self):
        row = ca.parse_event(
            host="nfe.gestaobem.com",
            payload=b"not-json",
            hosts=HOSTS,
            salt=b"x" * 32,
            ip="1.1.1.1",
            ua="ua",
            day="2026-10-01",
        )
        self.assertIsNone(row)

    def test_path_max_512(self):
        long_path = "/" + "a" * 600
        payload = json.dumps(
            {"n": "pageview", "u": "https://nfe.gestaobem.com" + long_path, "r": ""}
        ).encode()
        row = ca.parse_event(
            host="nfe.gestaobem.com",
            payload=payload,
            hosts=HOSTS,
            salt=b"x" * 32,
            ip="1.1.1.1",
            ua="ua",
            day="2026-10-01",
        )
        self.assertIsNotNone(row)
        self.assertEqual(len(row["path"]), 512)

    def test_utm_max_128(self):
        long = "g" * 200
        payload = json.dumps(
            {
                "n": "pageview",
                "u": "https://nfe.gestaobem.com/?utm_source=" + long,
                "r": "",
            }
        ).encode()
        row = ca.parse_event(
            host="nfe.gestaobem.com",
            payload=payload,
            hosts=HOSTS,
            salt=b"x" * 32,
            ip="1.1.1.1",
            ua="ua",
            day="2026-10-01",
        )
        self.assertIsNotNone(row)
        self.assertEqual(len(row["utm_source"]), 128)
        self.assertNotIn("ip", row)
        self.assertNotIn("ua", row)

    def test_host_accepts_case_and_port(self):
        salt = b"x" * 32
        payload = b'{"n":"pageview","u":"https://nfe.gestaobem.com/login","r":""}'
        expected_hash = ca.visitor_hash(
            salt, "1.1.1.1", "ua", "nfe.gestaobem.com", "2026-10-01"
        )
        for incoming in ("NFE.gestaobem.com", "nfe.gestaobem.com:443"):
            row = ca.parse_event(
                host=incoming,
                payload=payload,
                hosts=HOSTS,
                salt=salt,
                ip="1.1.1.1",
                ua="ua",
                day="2026-10-01",
            )
            self.assertIsNotNone(row, incoming)
            self.assertEqual(row["host"], "nfe.gestaobem.com")
            self.assertEqual(row["visitor_hash"], expected_hash)

    def test_store_and_prune(self):
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            store = ca.Store(path)
            store.insert_hit(ts=1, host="nfe.gestaobem.com", path="/", referrer="", utm_source="g", utm_medium="", utm_campaign="", visitor_hash="ab", name="pageview")
            store.rollup_and_prune(now_ts=1 + 8 * 86400)
            self.assertEqual(store.count_hits(), 0)
            self.assertGreater(store.count_daily_totals(), 0)
            self.assertEqual(
                store.conn.execute(
                    "SELECT pageviews, unique_visitors FROM daily_totals WHERE host=?",
                    ("nfe.gestaobem.com",),
                ).fetchone(),
                (1, 1),
            )
            self.assertEqual(
                store.conn.execute(
                    "SELECT path, pageviews FROM daily_paths"
                ).fetchone(),
                ("/", 1),
            )
            self.assertEqual(
                store.conn.execute(
                    "SELECT referrer, pageviews FROM daily_referrers"
                ).fetchone(),
                ("", 1),
            )
            self.assertEqual(
                store.conn.execute(
                    "SELECT utm_source, utm_medium, utm_campaign, pageviews FROM daily_utm"
                ).fetchone(),
                ("g", "", "", 1),
            )
        finally:
            os.remove(path)

    def test_rollup_freezes_partial_raw_day(self):
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        host = "nfe.gestaobem.com"
        day_start = int(datetime(2026, 9, 24, tzinfo=timezone.utc).timestamp())
        try:
            store = ca.Store(path)
            for _ in range(100):
                store.insert_hit(
                    ts=day_start,
                    host=host,
                    path="/",
                    referrer="",
                    utm_source="g",
                    utm_medium="",
                    utm_campaign="",
                    visitor_hash="aa",
                    name="pageview",
                )
            for _ in range(50):
                store.insert_hit(
                    ts=day_start + 12 * 3600,
                    host=host,
                    path="/",
                    referrer="",
                    utm_source="g",
                    utm_medium="",
                    utm_campaign="",
                    visitor_hash="bb",
                    name="pageview",
                )
            # now_ts such that the 7d cutoff splits this UTC day.
            now_ts = day_start + 6 * 3600 + 7 * 86400
            store.rollup_and_prune(now_ts=now_ts)
            store.rollup_and_prune(now_ts=now_ts)
            self.assertEqual(
                store.conn.execute(
                    "SELECT pageviews, unique_visitors FROM daily_totals WHERE day=? AND host=?",
                    ("2026-09-24", host),
                ).fetchone(),
                (150, 2),
            )
        finally:
            os.remove(path)

    def test_trim_does_not_vacuum(self):
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            store = ca.Store(path)
            executed = []

            class Cursor:
                def fetchone(self):
                    return ("1970-01-01",)

            class Conn:
                def execute(self, sql, *args, **kwargs):
                    executed.append(sql if isinstance(sql, str) else str(sql))
                    return Cursor()

                def commit(self):
                    return None

            store.conn = Conn()
            sizes = iter([ca.DB_MAX_BYTES + 1, ca.DB_TARGET_BYTES + 1, 0])
            store._db_size = lambda: next(sizes, 0)
            store._trim_if_oversized()
            joined = "\n".join(executed).upper()
            self.assertIn("DELETE FROM HITS", joined)
            self.assertIn("WAL_CHECKPOINT", joined)
            self.assertNotIn("VACUUM", joined)
        finally:
            try:
                store.close()
            except Exception:
                pass
            os.remove(path)

    def test_rollup_loop_logs_failure(self):
        class Boom:
            def rollup_and_prune(self, now_ts):
                raise RuntimeError("disk full")

        class Once:
            def __init__(self):
                self.n = 0

            def wait(self, timeout):
                self.n += 1
                return self.n > 1

        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            ca._rollup_loop(Boom(), Once())
        err = buf.getvalue()
        self.assertIn("disk full", err)
        self.assertNotIn("1.1.1.1", err)


class HttpTest(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix="cleat-analytics-")
        self.db_path = os.path.join(self._tmpdir, "analytics.db")
        self.hosts_path = os.path.join(self._tmpdir, "hosts.json")
        self.salt_path = os.path.join(self._tmpdir, "salt")
        with open(self.hosts_path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "nfe.gestaobem.com": {
                        "slug": "nfe-facil",
                        "upstream": "127.0.0.1:9",
                    }
                },
                fh,
            )
        with open(self.salt_path, "wb") as fh:
            fh.write(b"s" * 32)
        self._env = {
            "CLEAT_ANALYTICS_DB": self.db_path,
            "CLEAT_ANALYTICS_HOSTS": self.hosts_path,
            "CLEAT_ANALYTICS_SALT": self.salt_path,
            "CLEAT_ANALYTICS_PORT": "0",
        }
        self._old_env = {key: os.environ.get(key) for key in self._env}
        os.environ.update(self._env)
        self.httpd = ca.make_httpd()
        self.port = self.httpd.server_address[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self._wait_up()

    def tearDown(self):
        try:
            self.httpd.shutdown()
            self.httpd.server_close()
        except Exception:
            pass
        store = getattr(self.httpd, "store", None)
        if store is not None:
            try:
                store.close()
            except Exception:
                pass
        for key, value in self._old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _wait_up(self):
        url = self.base + "/healthz"
        last = None
        for _ in range(50):
            try:
                with urllib.request.urlopen(url, timeout=0.2) as resp:
                    if resp.status == 200:
                        return
            except Exception as exc:
                last = exc
            time.sleep(0.05)
        self.fail(f"server did not start: {last}")

    def _request(self, path, method="GET", data=None, host="nfe.gestaobem.com", headers=None):
        hdrs = {"Host": host}
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=2) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as err:
            return err.code, err.headers, err.read()

    def _post_pageview(self, host="nfe.gestaobem.com", extra=None):
        payload = {"n": "pageview", "u": "https://nfe.gestaobem.com/login", "r": "https://google.com/q"}
        if extra:
            payload.update(extra)
        status, _, _ = self._request(
            "/cleat/a",
            method="POST",
            data=json.dumps(payload).encode(),
            host=host,
            headers={"Content-Type": "application/json", "User-Agent": "ua"},
        )
        return status

    def _hit_count(self):
        conn = sqlite3.connect(self.db_path)
        try:
            return conn.execute("SELECT COUNT(*) FROM hits").fetchone()[0]
        finally:
            conn.close()

    def test_healthz(self):
        status, _, _ = self._request("/healthz")
        self.assertEqual(status, 200)

    def test_script(self):
        status, headers, body = self._request("/cleat/a.js")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/javascript")
        self.assertIn("max-age=3600", headers.get("Cache-Control", ""))
        self.assertIn("public", headers.get("Cache-Control", ""))
        self.assertIn("sendBeacon", body.decode())

    def test_collect_pageview(self):
        status = self._post_pageview()
        self.assertEqual(status, 204)
        self.assertEqual(self._hit_count(), 1)
        conn = sqlite3.connect(self.db_path)
        try:
            sql = conn.execute(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='hits'"
            ).fetchone()[0]
            self.assertNotIn(" ip", " " + sql.lower())
            cols = [row[1].lower() for row in conn.execute("PRAGMA table_info(hits)")]
            self.assertNotIn("ip", cols)
            self.assertNotIn("ua", cols)
            self.assertNotIn("user_agent", cols)
            row = dict(
                zip(
                    cols,
                    conn.execute("SELECT * FROM hits").fetchone(),
                )
            )
            self.assertNotIn("ip", row)
        finally:
            conn.close()

    def test_unknown_host_no_row(self):
        status = self._post_pageview(host="nope.example")
        self.assertEqual(status, 204)
        self.assertEqual(self._hit_count(), 0)

    def test_visited_24h(self):
        self.assertEqual(self._post_pageview(), 204)
        status, _, body = self._request("/v1/visited?range=24h")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertIsInstance(payload, list)
        self.assertGreaterEqual(len(payload), 1)
        self.assertEqual(payload[0]["host"], "nfe.gestaobem.com")
        self.assertEqual(payload[0]["slug"], "nfe-facil")
        self.assertGreaterEqual(payload[0]["pageviews"], 1)

    def test_app_summary_24h(self):
        self.assertEqual(
            self._post_pageview(
                extra={
                    "u": "https://nfe.gestaobem.com/login?utm_source=google&utm_medium=cpc&utm_campaign=a"
                }
            ),
            204,
        )
        status, _, body = self._request("/v1/apps/nfe.gestaobem.com?range=24h")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        for key in ("pageviews", "uniques", "series", "paths", "referrers", "utm"):
            self.assertIn(key, payload)
        self.assertGreaterEqual(len(payload["utm"]), 1)
        utm = payload["utm"][0]
        self.assertEqual(utm.get("source"), "google")
        self.assertEqual(utm.get("medium"), "cpc")
        self.assertEqual(utm.get("campaign"), "a")
        self.assertNotIn("utm_source", utm)

    def test_invalid_hosts_keeps_last_good(self):
        self.assertEqual(self._post_pageview(), 204)
        self.assertEqual(self._hit_count(), 1)
        with open(self.hosts_path, "w", encoding="utf-8") as fh:
            fh.write("{not-json")
        self.assertEqual(self._post_pageview(), 204)
        self.assertEqual(self._hit_count(), 2)

    def test_oversized_body_no_row(self):
        status, _, _ = self._request(
            "/cleat/a",
            method="POST",
            data=b"x" * (8 * 1024 + 1),
            headers={"Content-Type": "text/plain", "User-Agent": "ua"},
        )
        self.assertEqual(status, 204)
        self.assertEqual(self._hit_count(), 0)


if __name__ == "__main__":
    unittest.main()

