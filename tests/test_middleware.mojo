"""Phase 4 — middleware coverage.

Tests the three opt-in helpers: security headers, rate limit, and
request log formatter. All are pure functions / value-state structs,
so the tests are completely deterministic — no sockets, no clocks
(we pass `now_s` to the rate limiter explicitly).
"""

from std.collections import Dict
from std.time import perf_counter_ns

from baldr.request import Request
from baldr.response import Response
from baldr.middleware.security_headers import apply_security_headers, DEFAULT_CSP
from baldr.middleware.ratelimit import RateLimit, make_429, now_epoch_s
from baldr.middleware.logger import format_log_line


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int

    def __init__(out self):
        self.total = 0
        self.failures = 0

    def check(mut self, label: String, cond: Bool):
        self.total += 1
        if cond:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)

    def summary(self):
        print("---")
        if self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.failures, "of", self.total, "FAILED")


def _bytes_to_str(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


# ── Security headers ──────────────────────────────────────────────────────
def test_security_headers_full(mut r: Runner) raises:
    var resp = apply_security_headers(Response.text(String("hi")))
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("X-Content-Type-Options"), s.find(String("X-Content-Type-Options: nosniff")) > 0)
    r.check(String("X-Frame-Options"), s.find(String("X-Frame-Options: DENY")) > 0)
    r.check(String("Referrer-Policy"), s.find(String("Referrer-Policy: no-referrer")) > 0)
    r.check(String("CSP default-src"), s.find(String("Content-Security-Policy: default-src 'self'")) > 0)
    r.check(String("Permissions-Policy"), s.find(String("Permissions-Policy: geolocation=()")) > 0)
    r.check(String("status unchanged"), resp.status == 200)
    r.check(String("body unchanged"), _bytes_to_str(resp.body) == "hi")


def test_security_headers_custom_csp(mut r: Runner) raises:
    var csp = String("default-src 'none'")
    var resp = apply_security_headers(Response.text(String("ok")), csp=csp)
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("custom CSP wins"), s.find(String("Content-Security-Policy: default-src 'none'")) > 0)
    r.check(String("default CSP gone"), s.find(String("style-src 'self' https://fonts")) < 0)


# ── Rate limit ────────────────────────────────────────────────────────────
def test_ratelimit_first_hit_passes(mut r: Runner) raises:
    var limiter = RateLimit()
    r.check(String("first hit passes"), limiter.check(String("/scan"), 5, 1000) == 0)


def test_ratelimit_blocks_within_cooldown(mut r: Runner) raises:
    var limiter = RateLimit()
    _ = limiter.check(String("/scan"), 5, 1000)
    var retry = limiter.check(String("/scan"), 5, 1002)
    r.check(String("blocks within cooldown"), retry == 3)


def test_ratelimit_passes_after_cooldown(mut r: Runner) raises:
    var limiter = RateLimit()
    _ = limiter.check(String("/scan"), 5, 1000)
    r.check(String("passes at boundary"), limiter.check(String("/scan"), 5, 1005) == 0)
    r.check(String("passes well past"), limiter.check(String("/scan"), 5, 1020) == 0)


def test_ratelimit_independent_keys(mut r: Runner) raises:
    var limiter = RateLimit()
    _ = limiter.check(String("/scan"), 5, 1000)
    _ = limiter.check(String("/bench"), 5, 1000)
    r.check(String("/scan blocked"), limiter.check(String("/scan"), 5, 1001) == 4)
    r.check(String("/bench blocked"), limiter.check(String("/bench"), 5, 1001) == 4)
    var noop = limiter.check(String("/other"), 5, 1001)
    r.check(String("third key passes"), noop == 0)


def test_ratelimit_reset(mut r: Runner) raises:
    var limiter = RateLimit()
    _ = limiter.check(String("/scan"), 5, 1000)
    limiter.reset(String("/scan"))
    r.check(String("after reset passes"), limiter.check(String("/scan"), 5, 1001) == 0)


def test_make_429(mut r: Runner) raises:
    var resp = make_429(3, String("security scan"))
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("429 status"), s.find(String("HTTP/1.1 429 Too Many Requests")) == 0)
    r.check(String("Retry-After: 3"), s.find(String("Retry-After: 3")) > 0)
    r.check(String("error JSON includes reason"), s.find(String("security scan")) > 0)
    r.check(String("Cache-Control: no-store"), s.find(String("Cache-Control: no-store")) > 0)


def test_now_epoch_s_sane(mut r: Runner) raises:
    """Sanity-check that libc time() returns a plausible value."""
    var t = now_epoch_s()
    r.check(String("now > 2026 epoch"), t > 1767139200)  # 2026-01-01
    r.check(String("now < 2030 epoch"), t < 1893456000)  # 2030-01-01


# ── Logger ────────────────────────────────────────────────────────────────
def test_format_log_line_basic(mut r: Runner) raises:
    var req = Request()
    req.method = String("GET")
    req.path = String("/api/echo")

    var resp = Response.text(String("hello"))
    var t0 = perf_counter_ns()
    # Tiny sleep-equivalent: just call a function so elapsed > 0.
    _ = req.method.byte_length()

    var line = format_log_line(req, resp, t0)
    r.check(String("log starts with method"), line.find(String("GET ")) == 0)
    r.check(String("log includes path"), line.find(String("/api/echo")) > 0)
    r.check(String("log shows 200"), line.find(String("→ 200")) > 0)
    r.check(String("log shows byte count"), line.find(String("5 bytes")) > 0)
    r.check(String("log shows ms"), line.find(String("ms)")) > 0)


def test_format_log_line_404(mut r: Runner) raises:
    var req = Request()
    req.method = String("POST")
    req.path = String("/missing")
    var resp = Response.text(String("not found"), 404)
    var line = format_log_line(req, resp, perf_counter_ns())
    r.check(String("404 status"), line.find(String("→ 404")) > 0)
    r.check(String("POST method"), line.find(String("POST")) == 0)


def main() raises:
    var r = Runner()

    test_security_headers_full(r)
    test_security_headers_custom_csp(r)

    test_ratelimit_first_hit_passes(r)
    test_ratelimit_blocks_within_cooldown(r)
    test_ratelimit_passes_after_cooldown(r)
    test_ratelimit_independent_keys(r)
    test_ratelimit_reset(r)
    test_make_429(r)
    test_now_epoch_s_sane(r)

    test_format_log_line_basic(r)
    test_format_log_line_404(r)

    r.summary()
