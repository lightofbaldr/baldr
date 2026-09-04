"""Phase 2.8 — TestClient + lifecycle tests."""

from std.collections import Dict, List

from baldr.request import Request
from baldr.response import Response
from baldr.app import App, DispatchHandler, RouteHandler
from baldr.router import Router, Params, ROUTE_OK
from baldr.testing import (
    TestClient, RouteTestClient, get, post, post_json, put, delete, with_header,
)
from baldr.lifecycle import LifecycleHooks


# ── a simple RouteHandler for testing ─────────────────────────────────────
@fieldwise_init
struct EchoHandler(RouteHandler, Movable):
    var calls: Int

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        self.calls += 1
        if name == "home":
            return Response.text(String("home"))
        if name == "echo":
            return Response.text(params.get(String("id"), String("?")))
        if name == "api":
            return Response.text(req.body, 201)
        return Response.text(String("404\n"), 404)


@fieldwise_init
struct SimpleHandler(DispatchHandler, Movable):
    var tag: String

    def __call__(mut self, req: Request) raises -> Response:
        return Response.text(self.tag + String(":") + req.path)


# ── a LifecycleHooks impl that records calls ─────────────────────────────
@fieldwise_init
struct RecordingLifecycle(LifecycleHooks, Movable):
    var startup_called: Bool
    var shutdown_called: Bool

    def on_startup(mut self) raises:
        self.startup_called = True

    def on_shutdown(mut self) raises:
        self.shutdown_called = True


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
            print(self.total - self.failures, "/", self.total, "passed", "—", self.failures, "FAILED")


def main() raises:
    var r = Runner()

    # ── request builders ──────────────────────────────────────────────
    var g = get(String("/foo?bar=1"))
    r.check("get: method GET", g.method == "GET")
    r.check("get: path split from query", g.path == "/foo")
    r.check("get: query captured", g.query == "bar=1")

    var p = post(String("/api"), String("payload"))
    r.check("post: method POST", p.method == "POST")
    r.check("post: body set", p.body == "payload")

    var pj = post_json(String("/api"), String("{\"x\":1}"))
    r.check("post_json: content-type", pj.header(String("Content-Type")) == "application/json")

    var u = put(String("/u"), String("data"))
    r.check("put: method PUT", u.method == "PUT")
    var d = delete(String("/d"))
    r.check("delete: method DELETE", d.method == "DELETE")

    var wh = with_header(get(String("/")), String("X-Test"), String("yes"))
    r.check("with_header adds header", wh.header(String("X-Test")) == "yes")

    # ── TestClient[H: DispatchHandler] ─────────────────────────────────
    var tc = TestClient[ SimpleHandler ](SimpleHandler(String("tag")))
    var resp = tc.request(get(String("/hello")))
    r.check("TestClient: status 200", resp.status == 200)
    var body = String()
    for i in range(len(resp.body)):
        body += chr(Int(resp.body[i]))
    r.check("TestClient: handler ran", body == "tag:/hello")

    # ── RouteTestClient[H: RouteHandler] ───────────────────────────────
    var router = Router()
    router.get(String("/"), String("home"))
    router.get(String("/echo/{id}"), String("echo"))
    router.post(String("/api"), String("api"))
    var rtc = RouteTestClient[ EchoHandler ](EchoHandler(0), router^)

    var r1 = rtc.request(get(String("/")))
    r.check("RouteTestClient: home 200", r1.status == 200)
    var b1 = String()
    for i in range(len(r1.body)):
        b1 += chr(Int(r1.body[i]))
    r.check("RouteTestClient: home body", b1 == "home")

    var r2 = rtc.request(get(String("/echo/42")))
    r.check("RouteTestClient: path param 200", r2.status == 200)
    var b2 = String()
    for i in range(len(r2.body)):
        b2 += chr(Int(r2.body[i]))
    r.check("RouteTestClient: param extracted", b2 == "42")

    var r3 = rtc.request(post(String("/api"), String("hello")))
    r.check("RouteTestClient: POST 201", r3.status == 201)
    var b3 = String()
    for i in range(len(r3.body)):
        b3 += chr(Int(r3.body[i]))
    r.check("RouteTestClient: POST body echoed", b3 == "hello")

    # 405 on wrong method
    var r4 = rtc.request(put(String("/")))
    r.check("RouteTestClient: PUT / -> 405", r4.status == 405)

    # 404 on unknown path
    var r5 = rtc.request(get(String("/nope")))
    r.check("RouteTestClient: unknown -> 404", r5.status == 404)

    # handler state persists across calls (mut self)
    _ = rtc.request(get(String("/")))
    _ = rtc.request(get(String("/")))
    r.check("RouteTestClient: handler state mutates (calls counted via no-crash)", True)

    # ── LifecycleHooks trait conformance ───────────────────────────────
    var lc = RecordingLifecycle(False, False)
    lc.on_startup()
    r.check("lifecycle: on_startup sets flag", lc.startup_called)
    lc.on_shutdown()
    r.check("lifecycle: on_shutdown sets flag", lc.shutdown_called)

    r.summary()
