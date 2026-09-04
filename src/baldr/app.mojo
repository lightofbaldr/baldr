"""baldr.App — public router + accept loop.

Layers on top of the vendored `http` and `serve` primitives.

In v0.1 the request handler is a **struct that conforms to the
`DispatchHandler` trait** (implements `__call__(self, req) raises ->
Response`). The trait pattern matches Mojo 1.0's first-class function
story: traits give us runtime polymorphism without depending on the
function-pointer-storage support that Mojo 1.0 doesn't yet guarantee.

The dispatcher struct gets to own its state — rate limiter, queues,
templates, etc. — which keeps the bundle's hello / chat / scan
examples honest single-file Mojo binaries.

    @fieldwise_init
    struct HelloApp(DispatchHandler, Copyable, Movable):
        var name: String

        def __call__(self, req: Request) raises -> Response:
            return Response.text(String("hello, ") + self.name)

    def main() raises:
        var app = App()
        app.static(String("/static"), String("./static"))
        app.run(HelloApp(String("world")), port=8080)

Per-route `.get/.post/.put/.delete` registration lands in v0.2 once
Mojo's storable-fn-pointer story stabilizes.

Static mounts ARE registered at runtime since they're pure data.
"""

from std.ffi import c_int
from std.pathlib import Path

from .http import (
    socket_create, socket_reuseaddr, make_sockaddr_in,
    socket_bind, socket_listen, socket_accept, socket_close,
    read_request, write_all, socket_peer_ip,
)
from .request import Request, parse_request
from .response import Response
from .router import (
    Params, Router, Match,
    ROUTE_OK, ROUTE_METHOD_NOT_ALLOWED, ROUTE_NOT_FOUND,
)
from .middleware.chain import Middleware, MW_PASS
from .assets import AssetManifest
from .response import Header
from .errors import ErrorHandler, JsonErrorHandler
from .lifecycle import LifecycleHooks
from .serve import safe_join


trait DispatchHandler(Movable, Deinitable):
    """A request dispatcher. Conform a struct to this trait, hand the
    instance to `App.run()`, and the accept loop will call
    `__call__(req)` on each incoming request. The mutable `self`
    binding lets dispatchers carry per-server state (rate limiters,
    counters, caches) across requests."""
    def __call__(mut self, req: Request) raises -> Response: ...


trait RouteHandler(Movable, Deinitable):
    """A route-aware dispatcher. Used with `App.run_routes()`: the App
    resolves the request against its route table first, then calls
    `__call__(req, params, name)` with the matched route's extracted
    path params (empty on a no-param route) and the matched route's
    NAME (empty when no route matched). Branch on `name` to dispatch —
    `if name == "note_show":` — instead of re-inspecting `req.path`, so
    the route table you registered stays the single source of truth.
    (Mojo 1.0 has no storable fn pointers, so name-dispatch lives in the
    handler rather than binding each route to a function; threading the
    resolved name in keeps the handler from re-deriving it.)"""
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response: ...


struct StaticMount(Copyable, Movable):
    var prefix: String
    var dir: String

    def __init__(out self, prefix: String, dir: String):
        self.prefix = prefix
        self.dir = dir


struct App(Copyable, Movable):
    """Router + accept loop. v0.1 uses trait-typed dispatch."""
    var statics: List[StaticMount]
    var router: Router
    var has_router: Bool
    var has_assets: Bool
    var asset_manifest: AssetManifest

    def __init__(out self):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()

    def static(mut self, prefix: String, dir: String):
        """Serve everything under `dir` at URL `prefix/`."""
        self.statics.append(StaticMount(prefix, dir))

    def route(mut self, method: String, pattern: String, name: String):
        """Register a route. Routes are consulted by `run_routes()` before
        the handler. Static mounts still win over routes."""
        self.has_router = True
        self.router.route(method, pattern, name)

    def get(mut self, pattern: String, name: String):
        self.route(String("GET"), pattern, name)

    def post(mut self, pattern: String, name: String):
        self.route(String("POST"), pattern, name)

    def put(mut self, pattern: String, name: String):
        self.route(String("PUT"), pattern, name)

    def delete(mut self, pattern: String, name: String):
        self.route(String("DELETE"), pattern, name)

    def patch(mut self, pattern: String, name: String):
        self.route(String("PATCH"), pattern, name)

    def assets(mut self, var manifest: AssetManifest, url_prefix: String = String("/static")):
        """Register an asset-aware static mount backed by an `AssetManifest`.

        Requests for a manifest URL (e.g. `/static/app.abc123.js`) are served
        from the manifest's cached bytes with aggressive immutable caching:
            Cache-Control: public, max-age=31536000, immutable
            ETag: "<hash>"
        Unknown URLs under `url_prefix` fall through to a 404. Static mounts
        registered via `static()` still win over everything; this asset mount
        is consulted after static mounts and before routes/handler."""
        self.has_assets = True
        self.asset_manifest = manifest^

    def dispatch_static(self, req: Request) raises -> Response:
        """Resolve a request against the static mount table.
        Raises if no mount matches — callers fall through to their
        own dispatcher when this raises."""
        for i in range(len(self.statics)):
            ref m = self.statics[i]
            # Require a path-segment boundary: '/static' must match '/static'
            # and '/static/...' but NOT '/static-secret'. Plain startswith()
            # allows a prefix-boundary bypass that routes unrelated paths into
            # the static handler.
            if req.path == m.prefix or req.path.startswith(m.prefix + "/"):
                if req.method != "GET" and req.method != "HEAD":
                    return Response.text(String("405 method not allowed\n"), 405)
                var sub = String(req.path[byte=m.prefix.byte_length():])
                if sub.byte_length() > 0 and sub[byte=0:1] == "/":
                    # Materialize before assigning: `sub = String(sub[byte=1:])` reads `sub`
                    # immutably while `sub` is also the construction target, which
                    # dev2026080106 rejects as aliasing. The temporary completes the read
                    # first, then transfers.
                    var stripped = String(sub[byte=1:])
                    sub = stripped^
                var fs = safe_join(m.dir, sub)
                return Response.file(fs)
        raise Error(String("baldr: no static mount matches"))

    def dispatch_assets(self, req: Request) raises -> Response:
        """Serve an asset from the manifest. Raises if the request path is not
        a manifest URL — callers fall through to routes/handler."""
        if not self.has_assets:
            raise Error(String("baldr: no asset mount"))
        # Only manifest URLs are ours; everything else falls through.
        if not self.asset_manifest.has_url(req.path):
            raise Error(String("baldr: asset not in manifest"))
        if req.method != "GET" and req.method != "HEAD":
            return Response.text(String("405 method not allowed\n"), 405)
        var h = self.asset_manifest.hash_for_url(req.path)
        # Honor If-None-Match for a cheap 304.
        var inm = req.header(String("If-None-Match"))
        if inm.byte_length() > 0 and inm.find(h) >= 0:
            var n = Response()
            n.status = 304
            n.headers.append(Header(String("ETag"), String("\"") + h + String("\"")))
            return n^
        var r = Response()
        r.status = 200
        r.body = self.asset_manifest.bytes_for_url(req.path)
        r.headers.append(Header(String("Content-Type"), self.asset_manifest.content_type_for_url(req.path)))
        r.headers.append(Header(String("Cache-Control"), String("public, max-age=31536000, immutable")))
        r.headers.append(Header(String("ETag"), String("\"") + h + String("\"")))
        return r^

    def run[H: DispatchHandler](
        self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Start the accept loop. `handler` is a struct conforming to
        `DispatchHandler`; its `__call__(req)` is invoked per request.
        Static mounts win over the user handler; misses fall through."""
        var sock = socket_create()
        if Int(sock) < 0:
            raise Error(String("baldr: socket() failed"))
        _ = socket_reuseaddr(sock)
        var addr = make_sockaddr_in(port)
        if not socket_bind(sock, addr):
            socket_close(sock)
            raise Error(String("baldr: bind() failed on port ") + String(port))
        if not socket_listen(sock):
            socket_close(sock)
            raise Error(String("baldr: listen() failed"))

        print("[baldr] listening on", host, "port", port)
        while True:
            var client = socket_accept(sock)
            if Int(client) < 0:
                continue
            var raw = read_request(client)
            if len(raw) == 0:
                socket_close(client)
                continue

            var resp: Response
            try:
                var req = parse_request(raw, socket_peer_ip(client))
                try:
                    resp = self.dispatch_static(req)
                except:
                    try:
                        resp = self.dispatch_assets(req)
                    except:
                        resp = handler(req)
            except e:
                if String(e).startswith("400"):
                    resp = Response.text(String("400 Bad Request\n"), 400)
                else:
                    resp = Response.text(String("500 Internal Server Error\n"), 500)
            var resp_bytes = resp.to_bytes()
            write_all(client, resp_bytes)
            socket_close(client)

    def run_routes[H: RouteHandler](
        self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Start the accept loop with route-table dispatch. Routes
        registered via `route()`/`get()`/`post()`/... are resolved before
        the handler is called; on a match the handler receives the
        extracted path `params`. Static mounts still win over routes.
        A path match with a non-matching method yields 405 (with an
        `Allow` header); an unmatched path yields 404."""
        var sock = socket_create()
        if Int(sock) < 0:
            raise Error(String("baldr: socket() failed"))
        _ = socket_reuseaddr(sock)
        var addr = make_sockaddr_in(port)
        if not socket_bind(sock, addr):
            socket_close(sock)
            raise Error(String("baldr: bind() failed on port ") + String(port))
        if not socket_listen(sock):
            socket_close(sock)
            raise Error(String("baldr: listen() failed"))

        print("[baldr] listening on", host, "port", port, "(routes:", len(self.router.entries), ")")
        while True:
            var client = socket_accept(sock)
            if Int(client) < 0:
                continue
            var raw = read_request(client)
            if len(raw) == 0:
                socket_close(client)
                continue

            var resp: Response
            try:
                var req = parse_request(raw, socket_peer_ip(client))
                try:
                    resp = self.dispatch_static(req)
                except:
                    try:
                        resp = self.dispatch_assets(req)
                    except:
                        if self.has_router:
                            var m = self.router.resolve(req.method, req.path)
                            if m.status == ROUTE_OK:
                                resp = handler(req, m.params, m.name)
                            elif m.status == ROUTE_METHOD_NOT_ALLOWED:
                                resp = Response.text(
                                    String("405 method not allowed\n"), 405,
                                ).with_header(String("Allow"), m.allowed)
                            else:
                                resp = Response.text(String("404 not found\n"), 404)
                        else:
                            resp = handler(req, Params(), String())
            except e:
                if String(e).startswith("400"):
                    resp = Response.text(String("400 Bad Request\n"), 400)
                else:
                    resp = Response.text(String("500 Internal Server Error\n"), 500)
            var resp_bytes = resp.to_bytes()
            write_all(client, resp_bytes)
            socket_close(client)

    def run_routes_middleware[H: RouteHandler, *Ms: Middleware](
        self,
        var handler: H,
        *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Accept loop combining the route table and a middleware pipeline.

        Per request: static mounts win; else the middleware `before` chain runs
        (short-circuit on non-MW_PASS); on pass the route table is resolved and
        the handler called with params (405+Allow / 404 on miss); then the
        `after` chain mutates the response. The full-stack entry point used by
        the demo app."""
        var sock = socket_create()
        if Int(sock) < 0:
            raise Error(String("baldr: socket() failed"))
        _ = socket_reuseaddr(sock)
        var addr = make_sockaddr_in(port)
        if not socket_bind(sock, addr):
            socket_close(sock)
            raise Error(String("baldr: bind() failed on port ") + String(port))
        if not socket_listen(sock):
            socket_close(sock)
            raise Error(String("baldr: listen() failed"))

        print("[baldr] listening on", host, "port", port, "(routes:", len(self.router.entries), ", mw:", len(Ms), ")")
        while True:
            var client = socket_accept(sock)
            if Int(client) < 0:
                continue
            var raw = read_request(client)
            if len(raw) == 0:
                socket_close(client)
                continue

            var resp = Response()
            try:
                var req = parse_request(raw, socket_peer_ip(client))
                try:
                    resp = self.dispatch_static(req)
                except:
                    try:
                        resp = self.dispatch_assets(req)
                    except:
                        # before phase
                        var blocked = False
                        comptime for i in range(len(Ms)):
                            var pre = mws[i].before(req)
                            if pre.status != MW_PASS:
                                resp = pre^
                                blocked = True
                                break
                        if not blocked:
                            if self.has_router:
                                var m = self.router.resolve(req.method, req.path)
                                if m.status == ROUTE_OK:
                                    resp = handler(req, m.params, m.name)
                                elif m.status == ROUTE_METHOD_NOT_ALLOWED:
                                    resp = Response.text(
                                        String("405 method not allowed\n"), 405,
                                    ).with_header(String("Allow"), m.allowed)
                                else:
                                    resp = Response.text(String("404 not found\n"), 404)
                            else:
                                resp = handler(req, Params(), String())
                            # after phase
                            comptime for j in range(len(Ms)):
                                mws[j].after(req, resp)
            except e:
                if String(e).startswith("400"):
                    resp = Response.text(String("400 Bad Request\n"), 400)
                else:
                    resp = Response.text(String("500 Internal Server Error\n"), 500)
            var resp_bytes = resp.to_bytes()
            write_all(client, resp_bytes)
            socket_close(client)

    def run_routes_middleware_eh[H: RouteHandler, *Ms: Middleware, E: ErrorHandler](
        self,
        var handler: H,
        var eh: E,
        *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Full-stack runner with a custom error handler.

        Same as `run_routes_middleware`, but any exception in the accept loop
        is rendered via `eh.render_error(500, message, req)` instead of the
        plain-text `500 <error>` fallback. Use `JsonErrorHandler()` for API
        apps or `HtmlErrorHandler()` for browser apps, or conform your own."""
        var sock = socket_create()
        if Int(sock) < 0:
            raise Error(String("baldr: socket() failed"))
        _ = socket_reuseaddr(sock)
        var addr = make_sockaddr_in(port)
        if not socket_bind(sock, addr):
            socket_close(sock)
            raise Error(String("baldr: bind() failed on port ") + String(port))
        if not socket_listen(sock):
            socket_close(sock)
            raise Error(String("baldr: listen() failed"))

        print("[baldr] listening on", host, "port", port, "(routes:", len(self.router.entries), ", mw:", len(Ms), ", eh: on)")
        while True:
            var client = socket_accept(sock)
            if Int(client) < 0:
                continue
            var raw = read_request(client)
            if len(raw) == 0:
                socket_close(client)
                continue

            var resp = Response()
            var req = Request()
            var parsed = False
            try:
                req = parse_request(raw, socket_peer_ip(client))
                parsed = True
                try:
                    resp = self.dispatch_static(req)
                except:
                    try:
                        resp = self.dispatch_assets(req)
                    except:
                        var blocked = False
                        comptime for i in range(len(Ms)):
                            var pre = mws[i].before(req)
                            if pre.status != MW_PASS:
                                resp = pre^
                                blocked = True
                                break
                        if not blocked:
                            if self.has_router:
                                var m = self.router.resolve(req.method, req.path)
                                if m.status == ROUTE_OK:
                                    resp = handler(req, m.params, m.name)
                                elif m.status == ROUTE_METHOD_NOT_ALLOWED:
                                    resp = Response.text(
                                        String("405 method not allowed\n"), 405,
                                    ).with_header(String("Allow"), m.allowed)
                                else:
                                    resp = Response.text(String("404 not found\n"), 404)
                            else:
                                resp = handler(req, Params(), String())
                            comptime for j in range(len(Ms)):
                                mws[j].after(req, resp)
            except e:
                if parsed:
                    resp = eh.render_error(500, String("Internal Server Error"), req)
                else:
                    resp = Response.text(String("400 bad request\n"), 400)
            var resp_bytes = resp.to_bytes()
            write_all(client, resp_bytes)
            socket_close(client)

    def run_middleware[H: DispatchHandler, *Ms: Middleware](
        self,
        var handler: H,
        *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Accept loop with a comptime-monomorphized middleware pipeline.

        Each request: run `before` hooks in order (short-circuit on a
        non-zero-status response, e.g. 429); on pass, call `handler(req)`;
        then run `after` hooks in order over the response (mutate in place).
        Static mounts win over the whole pipeline. No route table.

        Usage:
            var app = App()
            app.run_middleware(
                MyHandler(),
                SecurityHeaders(),
                RequestLogger(),
                RateLimitMW(1),
            )
        """
        var sock = socket_create()
        if Int(sock) < 0:
            raise Error(String("baldr: socket() failed"))
        _ = socket_reuseaddr(sock)
        var addr = make_sockaddr_in(port)
        if not socket_bind(sock, addr):
            socket_close(sock)
            raise Error(String("baldr: bind() failed on port ") + String(port))
        if not socket_listen(sock):
            socket_close(sock)
            raise Error(String("baldr: listen() failed"))

        print("[baldr] listening on", host, "port", port, "(middleware:", len(Ms), "stages)")
        while True:
            var client = socket_accept(sock)
            if Int(client) < 0:
                continue
            var raw = read_request(client)
            if len(raw) == 0:
                socket_close(client)
                continue

            var resp = Response()
            try:
                var req = parse_request(raw, socket_peer_ip(client))
                try:
                    resp = self.dispatch_static(req)
                except:
                    try:
                        resp = self.dispatch_assets(req)
                    except:
                        # before phase: short-circuit on non-MW_PASS
                        var blocked = False
                        comptime for i in range(len(Ms)):
                            var pre = mws[i].before(req)
                            if pre.status != MW_PASS:
                                resp = pre^
                                blocked = True
                                break
                        if not blocked:
                            resp = handler(req)
                            # after phase: mutate resp in place
                            comptime for j in range(len(Ms)):
                                mws[j].after(req, resp)
            except e:
                if String(e).startswith("400"):
                    resp = Response.text(String("400 Bad Request\n"), 400)
                else:
                    resp = Response.text(String("500 Internal Server Error\n"), 500)
            var resp_bytes = resp.to_bytes()
            write_all(client, resp_bytes)
            socket_close(client)

    def run_full[H: RouteHandler, *Ms: Middleware, E: ErrorHandler, L: LifecycleHooks](
        self,
        var handler: H,
        var eh: E,
        var lifecycle: L,
        *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """The capstone runner: routes + middleware + error handler + lifecycle.

        - `lifecycle.on_startup()` runs once before binding.
        - Per request: static mounts -> asset mount -> middleware `before`
          (short-circuit) -> route table (405/404) -> handler -> `after`.
        - Any accept-loop exception -> `eh.render_error(500, msg, req)`.
        - `lifecycle.on_shutdown()` runs in a `finally` when the loop exits
          (e.g. Ctrl-C unwinds with an exception).
        """
        lifecycle.on_startup()
        try:
            var sock = socket_create()
            if Int(sock) < 0:
                raise Error(String("baldr: socket() failed"))
            _ = socket_reuseaddr(sock)
            var addr = make_sockaddr_in(port)
            if not socket_bind(sock, addr):
                socket_close(sock)
                raise Error(String("baldr: bind() failed on port ") + String(port))
            if not socket_listen(sock):
                socket_close(sock)
                raise Error(String("baldr: listen() failed"))

            print("[baldr] listening on", host, "port", port, "(routes:", len(self.router.entries), ", mw:", len(Ms), ", eh: on, lifecycle: on)")
            while True:
                var client = socket_accept(sock)
                if Int(client) < 0:
                    continue
                var raw = read_request(client)
                if len(raw) == 0:
                    socket_close(client)
                    continue

                var resp = Response()
                var req = Request()
                var parsed = False
                try:
                    req = parse_request(raw, socket_peer_ip(client))
                    parsed = True
                    try:
                        resp = self.dispatch_static(req)
                    except:
                        try:
                            resp = self.dispatch_assets(req)
                        except:
                            var blocked = False
                            comptime for i in range(len(Ms)):
                                var pre = mws[i].before(req)
                                if pre.status != MW_PASS:
                                    resp = pre^
                                    blocked = True
                                    break
                            if not blocked:
                                if self.has_router:
                                    var m = self.router.resolve(req.method, req.path)
                                    if m.status == ROUTE_OK:
                                        resp = handler(req, m.params, m.name)
                                    elif m.status == ROUTE_METHOD_NOT_ALLOWED:
                                        resp = Response.text(
                                            String("405 method not allowed\n"), 405,
                                        ).with_header(String("Allow"), m.allowed)
                                    else:
                                        resp = Response.text(String("404 not found\n"), 404)
                                else:
                                    resp = handler(req, Params(), String())
                                comptime for j in range(len(Ms)):
                                    mws[j].after(req, resp)
                except e:
                    if parsed:
                        resp = eh.render_error(500, String("Internal Server Error"), req)
                    else:
                        resp = Response.text(String("400 bad request\n"), 400)
                var resp_bytes = resp.to_bytes()
                write_all(client, resp_bytes)
                socket_close(client)
        finally:
            lifecycle.on_shutdown()
