"""baldr.middleware.ratelimit — per-key cooldown tracker.

A pure-state struct: handlers call `limiter.check(key, cooldown_s, now)`
to learn whether a request should pass or get rate-limited. The
companion `make_429()` builds a standard 429 response with `Retry-After`,
JSON body, and the same security headers `apply_security_headers`
would add.

Time is passed in by the caller (seconds since epoch) so the struct
stays deterministic and easy to test. `now_epoch_s()` is the
convenience that wraps libc `time(NULL)`.
"""

from std.collections import Dict
from std.ffi import external_call, c_size_t

from ..response import Response


def now_epoch_s() -> Int:
    """Seconds since the Unix epoch. Wraps libc `time(NULL)`."""
    return Int(external_call["time", c_size_t, c_size_t](c_size_t(0)))


struct RateLimit(Copyable, Movable):
    """Per-key cooldown tracker. One instance per logical limiter —
    a server can hold several (e.g. per-endpoint) without interference."""
    var last_hit_s: Dict[String, Int]

    def __init__(out self):
        self.last_hit_s = Dict[String, Int]()

    def check(mut self, key: String, cooldown_s: Int, now_s: Int) raises -> Int:
        """Returns 0 if the request passes, or the number of seconds
        the caller should wait before retrying. On 0, the caller's hit
        time is recorded so a subsequent call within `cooldown_s` will
        return a positive retry-after."""
        if self.last_hit_s.__contains__(key):
            var prev = self.last_hit_s[key]
            var elapsed = now_s - prev
            if elapsed < cooldown_s:
                return cooldown_s - elapsed
        self.last_hit_s[key] = now_s
        return 0

    def reset(mut self, key: String) raises:
        """Clear the cooldown for `key`. Useful in tests."""
        if self.last_hit_s.__contains__(key):
            _ = self.last_hit_s.pop(key)


def make_429(retry_after_s: Int, what: String) -> Response:
    """Build a standard 429 response with Retry-After + JSON body.
    Callers wrap with `apply_security_headers()` if they want the
    full hardening stack on the rate-limit path too."""
    var body = String("{\"ok\":false,\"error\":\"rate-limited: ") + what \
             + ", retry in " + String(retry_after_s) + "s\"}"
    return Response.text(body, 429) \
        .with_header(String("Content-Type"), String("application/json; charset=utf-8")) \
        .with_header(String("Retry-After"), String(retry_after_s)) \
        .with_header(String("Cache-Control"), String("no-store"))
