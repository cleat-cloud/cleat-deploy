import hashlib
import hmac
import json
import os
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
