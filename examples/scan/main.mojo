"""baldr — scan example.

Loads a synthetic corpus into a `CpuQueue` and exposes a one-route
JSON endpoint that runs `find_str(needle)` with timing. Demonstrates
the SIMD substring scan in real workload shape.

Build:
    pixi run example-scan
Run:
    build/example-scan
Probe (in another shell):
    curl 'http://127.0.0.1:8091/?q=needle&corpus=8mb'
    curl 'http://127.0.0.1:8091/?q=baldr&corpus=64mb'
"""

from std.time import perf_counter_ns

from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.json import JsonValue
from baldr.queue.cpu import CpuQueue, Match
from baldr.middleware.security_headers import apply_security_headers
from baldr.middleware.logger import log_request


# Synthetic corpus pattern — repeated alphabet + sentinel.
# Bytes-per-block ~= 64; sentinel "BALDR_MARKER" appears once per
# 100 blocks (~once every 6.4 KiB) so we get a non-trivial number of
# hits at scan time but the corpus is mostly miss-density.
def build_corpus(target_bytes: Int) raises -> CpuQueue:
    var q = CpuQueue(capacity=target_bytes * 2)
    var letters = String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    var block = letters + letters[byte=0:12]   # 64 bytes
    var sentinel = block[byte=0:48] + "BALDR_MARKER"  # 60 bytes
    var n_blocks = target_bytes // 64
    var i = 0
    while i < n_blocks:
        var s: String
        if i % 100 == 99:
            s = String(sentinel)
        else:
            s = String(block)
        var b = s.as_bytes()
        var L = List[UInt8](capacity=len(b))
        for k in range(len(b)):
            L.append(b[k])
        _ = q.push(L^)
        i += 1
    return q^


@fieldwise_init
struct ScanApp(DispatchHandler, Movable):
    var corpus_8mb: CpuQueue
    var corpus_64mb: CpuQueue

    def __call__(mut self, req: Request) raises -> Response:
        var t0 = perf_counter_ns()
        var resp: Response

        if req.method == "GET" and req.path == "/":
            # Parse query: q=needle&corpus=8mb|64mb
            var needle = String()
            var corpus_key = String("8mb")
            var parts = req.query.split(String("&"))
            for var p in parts:
                var ps = String(p)
                var eq = ps.find(String("="))
                if eq > 0:
                    var k = String(ps[byte=0:eq])
                    var v = String(ps[byte=eq + 1:])
                    if k == "q":
                        needle = v
                    elif k == "corpus":
                        corpus_key = v

            if needle.byte_length() == 0:
                resp = Response.html(String(
                    "<!doctype html><meta charset=utf-8>"
                    "<title>baldr — scan</title>"
                    "<h1>baldr — SIMD substring scan</h1>"
                    "<p>Try:</p>"
                    "<ul>"
                    "<li><a href='/?q=BALDR_MARKER&corpus=8mb'>?q=BALDR_MARKER&corpus=8mb</a></li>"
                    "<li><a href='/?q=BALDR_MARKER&corpus=64mb'>?q=BALDR_MARKER&corpus=64mb</a></li>"
                    "<li><a href='/?q=xyz&corpus=8mb'>?q=xyz&corpus=8mb</a></li>"
                    "</ul>"
                ))
            else:
                var t_scan_start = perf_counter_ns()
                var matches: List[Match]
                var corpus_bytes: Int
                if corpus_key == "64mb":
                    matches = self.corpus_64mb.find_str(needle)
                    corpus_bytes = self.corpus_64mb.tail
                else:
                    matches = self.corpus_8mb.find_str(needle)
                    corpus_bytes = self.corpus_8mb.tail
                var t_scan_end = perf_counter_ns()
                var elapsed_us = Int((t_scan_end - t_scan_start) // 1000)
                var gb_per_s_x100: Int
                if elapsed_us > 0:
                    # bytes/microsecond = MB/s; / 1000 = GB/s; *100 to keep 2-dec precision
                    gb_per_s_x100 = (corpus_bytes * 100) // (elapsed_us * 1000)
                else:
                    gb_per_s_x100 = 0

                var v = JsonValue.from_object()
                v.set(String("needle"), JsonValue.from_string(needle))
                v.set(String("corpus"), JsonValue.from_string(corpus_key))
                v.set(String("corpus_bytes"), JsonValue.from_int(corpus_bytes))
                v.set(String("matches"), JsonValue.from_int(len(matches)))
                v.set(String("elapsed_us"), JsonValue.from_int(elapsed_us))
                v.set(String("throughput_gbps_x100"), JsonValue.from_int(gb_per_s_x100))
                resp = Response.json(v^, 200)
        else:
            resp = Response.text(String("404\n"), 404)

        resp = apply_security_headers(resp^)
        log_request(req, resp, t0)
        return resp^


def main() raises:
    print("[scan] building 8 MB corpus...")
    var c8 = build_corpus(8 * 1024 * 1024)
    print("[scan] building 64 MB corpus...")
    var c64 = build_corpus(64 * 1024 * 1024)
    print("[scan] corpora ready (8 MB =", c8.tail, "bytes, 64 MB =", c64.tail, "bytes)")

    var app = App()
    app.run(ScanApp(c8^, c64^), port=8091)
