"""Phase 2.9 — prefork concurrency demo.

A stateless handler served by a 4-worker prefork pool. Each worker handles
requests on the shared listening socket. Run:
    pixi run example-concurrency && build/example-concurrency   (:8099)

Test concurrency (4 workers handle 4 slow requests in parallel):
    for i in 1 2 3 4; do time curl -s http://127.0.0.1:8099/slow; done
    # vs serial: all 4 finish in ~1s total, not ~4s
"""
from baldr.concurrency import run_concurrent
from baldr.request import Request
from baldr.response import Response
from baldr.app import DispatchHandler
from std.ffi import external_call, c_uint, c_int


def _sleep_s(s: Int):
    _ = external_call["sleep", c_uint, c_uint](c_uint(s))


@fieldwise_init
struct SlowHandler(DispatchHandler, Copyable, Movable):
    var tag: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/slow" and req.method == "GET":
            _sleep_s(1)   # 1s of work
            return Response.text(String("served by ") + self.tag + String(" (pid ") + String(Int(external_call["getpid", c_int]())) + String(")\n"))
        if req.path == "/" and req.method == "GET":
            return Response.text(String("ok\n"))
        return Response.text(String("404\n"), 404)


def main() raises:
    run_concurrent(SlowHandler(String("baldr-prefork")), port=8099, workers=4)
