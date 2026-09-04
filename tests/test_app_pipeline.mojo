"""App pipeline tests — the App carries its parts; one `run`; `handle()` in-process.

Covers: `App()` defaults, error handlers (text vs JSON), a single stateful
middleware, a `Chain` (ordering, short-circuit, `after` skipped on block),
route resolution (params, 405 + Allow, 404), a `DispatchHandler` ignoring the
route table, static mounts bypassing middleware, `RateLimitMW` per peer, and
the keyword-only constructors. No sockets: everything goes through
`App.handle(handler, req)`, which is the same pipeline `run()` drives.
"""

from std.os import makedirs
from std.pathlib import Path

from baldr.app import App, DispatchHandler, RouteHandler
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params
from baldr.middleware.chain import (
    Middleware, MW_PASS, Chain, NoMiddleware, SecurityHeaders, RequestLogger, RateLimitMW,
)
from baldr.errors import JsonErrorHandler, DefaultErrorHandler
from baldr.lifecycle import LifecycleHooks
from baldr.testing import get, post


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


def _body(resp: Response) -> String:
    var s = String()
    for i in range(len(resp.body)):
        s += chr(Int(resp.body[i]))
    return s^


def _header(resp: Response, key: String) -> String:
    for i in range(len(resp.headers)):
        if resp.headers[i].key == key:
            return resp.headers[i].value
    return String()


# ── Handlers ──────────────────────────────────────────────────────────────
@fieldwise_init
struct Echo(DispatchHandler, Copyable, Movable):
    """Routes by hand; counts calls; raises on /boom."""
    var calls: Int

    def __call__(mut self, req: Request) raises -> Response:
        self.calls += 1
        if req.path == "/boom":
            raise Error(String("kaboom"))
        return Response.text(String("echo:") + req.path)


@fieldwise_init
struct Named(RouteHandler, Copyable, Movable):
    """Dispatches on the matched route name; remembers the last one."""
    var last_name: String

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        self.last_name = name
        if name == "show":
            return Response.text(String("id=") + params.get(String("id")))
        return Response.text(String("unrouted:") + req.path)


# ── Middleware ────────────────────────────────────────────────────────────
@fieldwise_init
struct Counter(Middleware, Copyable, Movable):
    """Stateful: counts hooks and stamps the count on the response."""
    var befores: Int
    var afters: Int

    def before(mut self, req: Request) raises -> Response:
        self.befores += 1
        var r = Response()
        r.status = MW_PASS
        return r^

    def after(mut self, req: Request, mut resp: Response) raises:
        self.afters += 1
        resp.add_header(String("X-Count"), String(self.afters))


@fieldwise_init
struct Blocker(Middleware, Copyable, Movable):
    """Short-circuits /blocked with the given status."""
    var code: Int

    def before(mut self, req: Request) raises -> Response:
        if req.path == "/blocked":
            return Response.text(String("blocked\n"), self.code)
        var r = Response()
        r.status = MW_PASS
        return r^


struct Hooks(LifecycleHooks, Movable):
    var started: Int
    var stopped: Int

    def __init__(out self):
        self.started = 0
        self.stopped = 0

    def on_startup(mut self) raises:
        self.started += 1

    def on_shutdown(mut self) raises:
        self.stopped += 1


def main() raises:
    var r = Runner()

    # ── App() defaults + handler state ────────────────────────────────────
    var app = App()
    var echo = Echo(0)
    var resp = app.handle(echo, get(String("/x")))
    r.check(String("App(): 200"), resp.status == 200)
    r.check(String("App(): body from handler"), _body(resp) == "echo:/x")
    _ = app.handle(echo, get(String("/y")))
    r.check(String("handler keeps state across requests"), echo.calls == 2)

    # ── Default errors: plain text ───────────────────────────────────────
    var boom = app.handle(echo, get(String("/boom")))
    r.check(String("DefaultErrorHandler: 500"), boom.status == 500)
    r.check(String("DefaultErrorHandler: text body"), _body(boom) == "500 Internal Server Error\n")

    # ── JSON errors via the keyword-only constructor ─────────────────────
    var japp = App(errors=JsonErrorHandler())
    var jboom = japp.handle(echo, get(String("/boom")))
    r.check(String("JsonErrorHandler: 500"), jboom.status == 500)
    r.check(String("JsonErrorHandler: json body"), _body(jboom).find(String("internal_error")) >= 0)
    r.check(String("JsonErrorHandler: content type"), _header(jboom, String("Content-Type")).find(String("json")) >= 0)

    # ── One stateful middleware ──────────────────────────────────────────
    var mapp = App(middleware=Counter(0, 0))
    _ = mapp.handle(echo, get(String("/a")))
    var second = mapp.handle(echo, get(String("/b")))
    r.check(String("middleware.before ran twice"), mapp.middleware.befores == 2)
    r.check(String("middleware.after ran twice"), mapp.middleware.afters == 2)
    r.check(String("after stamped the response"), _header(second, String("X-Count")) == "2")

    # ── Chain: order, short-circuit, after skipped on block ──────────────
    var capp = App(middleware=Chain((Blocker(403), Counter(0, 0))))
    var blocked = capp.handle(echo, get(String("/blocked")))
    r.check(String("chain: blocker short-circuits with 403"), blocked.status == 403)
    r.check(String("chain: blocker body"), _body(blocked) == "blocked\n")
    r.check(String("chain: later before not run on block"), capp.middleware.stages[1].befores == 0)
    r.check(String("chain: after not run on block"), capp.middleware.stages[1].afters == 0)
    var calls_before = echo.calls
    var passed = capp.handle(echo, get(String("/ok")))
    r.check(String("chain: pass-through reaches handler"), echo.calls == calls_before + 1)
    r.check(String("chain: pass-through 200"), passed.status == 200)
    r.check(String("chain: later stage ran before"), capp.middleware.stages[1].befores == 1)
    r.check(String("chain: later stage ran after"), _header(passed, String("X-Count")) == "1")
    r.check(String("chain: handler not called on block"), echo.calls == calls_before + 1)

    # ── Routes with a RouteHandler ───────────────────────────────────────
    var rapp = App()
    rapp.get(String("/items/{id}"), String("show"))
    var named = Named(String())
    var shown = rapp.handle(named, get(String("/items/7")))
    r.check(String("routes: param extracted"), _body(shown) == "id=7")
    r.check(String("routes: name threaded"), named.last_name == "show")
    var wrong = rapp.handle(named, post(String("/items/7")))
    r.check(String("routes: 405 on method miss"), wrong.status == 405)
    r.check(String("routes: Allow header"), _header(wrong, String("Allow")).find(String("GET")) >= 0)
    var missing = rapp.handle(named, get(String("/nope")))
    r.check(String("routes: 404 on path miss"), missing.status == 404)

    # ── DispatchHandler ignores the route table ──────────────────────────
    var free = rapp.handle(echo, get(String("/anything")))
    r.check(String("DispatchHandler: route table ignored"), free.status == 200 and _body(free) == "echo:/anything")

    # ── Static mounts bypass middleware ──────────────────────────────────
    var tmpdir = String("build/pipeline_static")
    makedirs(Path(tmpdir), exist_ok=True)
    var content = String("static-bytes").as_bytes()
    var content_list = List[UInt8](capacity=len(content))
    for i in range(len(content)):
        content_list.append(content[i])
    Path(tmpdir + "/a.txt").write_bytes(content_list)
    var sapp = App(middleware=Counter(0, 0))
    sapp.static(String("/static"), tmpdir)
    var served = sapp.handle(echo, get(String("/static/a.txt")))
    r.check(String("static: served"), served.status == 200 and _body(served) == "static-bytes")
    r.check(String("static: middleware bypassed"), sapp.middleware.befores == 0 and sapp.middleware.afters == 0)

    # ── RateLimitMW per peer ─────────────────────────────────────────────
    var lapp = App(middleware=RateLimitMW(60, String("hits")))
    var first = get(String("/l"))
    first.peer = String("10.0.0.1")
    var again = get(String("/l"))
    again.peer = String("10.0.0.1")
    var other = get(String("/l"))
    other.peer = String("10.0.0.2")
    var r1 = lapp.handle(echo, first^)
    var r2 = lapp.handle(echo, again^)
    var r3 = lapp.handle(echo, other^)
    r.check(String("ratelimit: first request passes"), r1.status == 200)
    r.check(String("ratelimit: second within cooldown is 429"), r2.status == 429)
    r.check(String("ratelimit: Retry-After set"), _header(r2, String("Retry-After")).byte_length() > 0)
    r.check(String("ratelimit: other peer passes"), r3.status == 200)

    # ── RequestLogger is stateful now ────────────────────────────────────
    var logged = App(middleware=RequestLogger())
    _ = logged.handle(echo, get(String("/log")))
    r.check(String("RequestLogger: start stamped in before"), logged.middleware.start_ns > UInt(0))

    # ── Every constructor shape compiles and defaults the rest ───────────
    var c1 = App(middleware=Counter(0, 0), errors=JsonErrorHandler())
    var c2 = App(middleware=Counter(0, 0), errors=JsonErrorHandler(), lifecycle=Hooks())
    var c3 = App(lifecycle=Hooks())
    var c4 = App(errors=JsonErrorHandler(), lifecycle=Hooks())
    var c5 = App(middleware=SecurityHeaders(), lifecycle=Hooks())
    var c6 = App[E=JsonErrorHandler]()
    var hardened = c5.handle(echo, get(String("/h")))
    r.check(String("constructors: (middleware, errors)"), c1.handle(echo, get(String("/1"))).status == 200)
    r.check(String("constructors: (middleware, errors, lifecycle)"), c2.lifecycle.started == 0)
    r.check(String("constructors: lifecycle only"), c3.lifecycle.stopped == 0)
    r.check(String("constructors: errors + lifecycle"), c4.handle(echo, get(String("/boom"))).status == 500)
    r.check(String("constructors: middleware + lifecycle"), _header(hardened, String("X-Content-Type-Options")) == "nosniff")
    r.check(String("constructors: App[E=JsonErrorHandler]()"), _body(c6.handle(echo, get(String("/boom")))).find(String("internal_error")) >= 0)

    r.summary()
