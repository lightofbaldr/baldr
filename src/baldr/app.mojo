"""baldr.App — the server: mounts, routes, and one `run`.

An `App` is a static-mount table, an optional route table, an optional asset
mount, and the three optional parts of the request pipeline, carried as
**type parameters** with defaults:

    App[M: Middleware = NoMiddleware,
        E: ErrorHandler = DefaultErrorHandler,
        L: LifecycleHooks = NoLifecycle]

So `App()` is the bare server, and each part is added by handing a value to
the constructor — the compiler infers the types:

    var app = App(
        middleware=Chain((SecurityHeaders(), RequestLogger())),
        errors=JsonErrorHandler(),
        lifecycle=MyHooks(),
    )
    app.get("/users/{id}", "show_user")
    app.run(Api(), port=8080)

One `run`. It accepts either handler trait: a `DispatchHandler` (you route by
hand; the route table is ignored) or a `RouteHandler` (the table is resolved
first and the handler receives `params` and the matched route `name`).

Per request, in order: static mounts → asset mount → `middleware.before`
(a non-`MW_PASS` response short-circuits everything below) → route table
(405 with `Allow` / 404 on a miss, when routes are registered) → handler →
`middleware.after` → on any exception, `errors.render_error(500, ...)`.
`lifecycle.on_startup()` runs once before binding, `on_shutdown()` once
after the loop exits. `handle(handler, req)` runs that same pipeline on one
in-memory request, which is how you test an app without a socket.

Why parameters and not a builder chain: Mojo 1.0 cannot store a function or
a trait object in a struct field, but it can store a concrete `M` / `E` / `L`
and a `Chain[*Ms]` holds its stages in a `Tuple` — so the parts live on the
App as lvalues, which is also what lets middleware keep state (`mut self`).

The six `run_*` runners of v0.1 remain as deprecated wrappers; every call
that compiled before still compiles and behaves the same.
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
from .middleware.chain import Middleware, NoMiddleware, Chain, MW_PASS
from .assets import AssetManifest
from .response import Header
from .errors import ErrorHandler, DefaultErrorHandler, JsonErrorHandler
from .lifecycle import LifecycleHooks, NoLifecycle
from .serve import safe_join


trait DispatchHandler(Movable, Deinitable):
    """A request dispatcher. Conform a struct to this trait, hand the
    instance to `App.run()`, and the accept loop will call
    `__call__(req)` on each incoming request. The mutable `self`
    binding lets dispatchers carry per-server state (rate limiters,
    counters, caches) across requests."""
    def __call__(mut self, req: Request) raises -> Response: ...


trait RouteHandler(Movable, Deinitable):
    """A route-aware dispatcher. Used with `App.run()` when routes are
    registered: the App resolves the request against its route table first,
    then calls `__call__(req, params, name)` with the matched route's
    extracted path params (empty on a no-param route) and the matched route's
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


struct _RouteAdapter[H: DispatchHandler](RouteHandler, Movable, Deinitable):
    """Presents a `DispatchHandler` as a `RouteHandler` so the one accept
    loop serves both. The App never resolves routes for it."""
    var h: Self.H

    def __init__(out self, var h: Self.H):
        self.h = h^

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        return self.h(req)


struct App[
    M: Middleware = NoMiddleware,
    E: ErrorHandler = DefaultErrorHandler,
    L: LifecycleHooks = NoLifecycle,
](Movable):
    """Router + accept loop. The pipeline parts are the type parameters;
    see the module docstring."""
    var statics: List[StaticMount]
    var router: Router
    var has_router: Bool
    var has_assets: Bool
    var asset_manifest: AssetManifest
    var middleware: Self.M
    var errors: Self.E
    var lifecycle: Self.L

    # ── Constructors ─────────────────────────────────────────────────────
    # Every part is optional; a part you don't pass is default-constructed,
    # which is why the omitted parts must be `Defaultable` (all built-in
    # defaults are). Positional order is middleware, errors, lifecycle;
    # keyword-only overloads cover the combinations that skip a part.

    def __init__(out self) where conforms_to(Self.M, Defaultable) and conforms_to(Self.E, Defaultable) and conforms_to(Self.L, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = Self.M()
        self.errors = Self.E()
        self.lifecycle = Self.L()

    def __init__(out self, var middleware: Self.M) where conforms_to(Self.E, Defaultable) and conforms_to(Self.L, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = middleware^
        self.errors = Self.E()
        self.lifecycle = Self.L()

    def __init__(out self, var middleware: Self.M, var errors: Self.E) where conforms_to(Self.L, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = middleware^
        self.errors = errors^
        self.lifecycle = Self.L()

    def __init__(out self, var middleware: Self.M, var errors: Self.E, var lifecycle: Self.L):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = middleware^
        self.errors = errors^
        self.lifecycle = lifecycle^

    def __init__(out self, *, var errors: Self.E) where conforms_to(Self.M, Defaultable) and conforms_to(Self.L, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = Self.M()
        self.errors = errors^
        self.lifecycle = Self.L()

    def __init__(out self, *, var lifecycle: Self.L) where conforms_to(Self.M, Defaultable) and conforms_to(Self.E, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = Self.M()
        self.errors = Self.E()
        self.lifecycle = lifecycle^

    def __init__(out self, *, var errors: Self.E, var lifecycle: Self.L) where conforms_to(Self.M, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = Self.M()
        self.errors = errors^
        self.lifecycle = lifecycle^

    def __init__(out self, *, var middleware: Self.M, var lifecycle: Self.L) where conforms_to(Self.E, Defaultable):
        self.statics = List[StaticMount]()
        self.router = Router()
        self.has_router = False
        self.has_assets = False
        self.asset_manifest = AssetManifest()
        self.middleware = middleware^
        self.errors = Self.E()
        self.lifecycle = lifecycle^

    # ── Registration ─────────────────────────────────────────────────────
    def static(mut self, prefix: String, dir: String):
        """Serve everything under `dir` at URL `prefix/`."""
        self.statics.append(StaticMount(prefix, dir))

    def route(mut self, method: String, pattern: String, name: String):
        """Register a route. Routes are consulted by `run()` / `handle()`
        when the handler is a `RouteHandler`. Static mounts still win."""
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

    # ── Static + asset dispatch ──────────────────────────────────────────
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
                    # Materialize before assigning: reading `sub` while it is
                    # also the construction target is an aliasing error.
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

    def _serve_mounted(self, req: Request, mut resp: Response) -> Bool:
        """Static mounts, then the asset mount. True if one produced `resp`;
        mounted content bypasses middleware, routes and the handler."""
        try:
            resp = self.dispatch_static(req)
            return True
        except:
            pass
        try:
            resp = self.dispatch_assets(req)
            return True
        except:
            pass
        return False

    def _route_call[H: RouteHandler](self, mut handler: H, req: Request, use_router: Bool) raises -> Response:
        """Resolve the route table (when registered and wanted) and call the
        handler: 405 + `Allow` on a method miss, 404 on a path miss."""
        if use_router and self.has_router:
            var m = self.router.resolve(req.method, req.path)
            if m.status == ROUTE_OK:
                return handler(req, m.params, m.name)
            if m.status == ROUTE_METHOD_NOT_ALLOWED:
                return Response.text(
                    String("405 method not allowed\n"), 405,
                ).with_header(String("Allow"), m.allowed)
            return Response.text(String("404 not found\n"), 404)
        return handler(req, Params(), String())

    # ── The pipeline ─────────────────────────────────────────────────────
    def _pipeline[H: RouteHandler](mut self, mut handler: H, req: Request, use_router: Bool) raises -> Response:
        var resp = Response()
        if self._serve_mounted(req, resp):
            return resp^
        try:
            var pre = self.middleware.before(req)
            if pre.status != MW_PASS:
                return pre^
            resp = self._route_call(handler, req, use_router)
            self.middleware.after(req, resp)
            return resp^
        except e:
            return self.errors.render_error(500, String("Internal Server Error"), req)

    def handle[H: RouteHandler](mut self, mut handler: H, req: Request) raises -> Response:
        """Run one request through the whole pipeline in-process — mounts,
        middleware, route table, handler, error handler — and return the
        response. No socket; this is the unit-test entry point."""
        return self._pipeline(handler, req, True)

    def handle[H: DispatchHandler](mut self, mut handler: H, req: Request) raises -> Response:
        """`handle` for a `DispatchHandler`: same pipeline, route table ignored
        (you route by hand inside the handler)."""
        var resp = Response()
        if self._serve_mounted(req, resp):
            return resp^
        try:
            var pre = self.middleware.before(req)
            if pre.status != MW_PASS:
                return pre^
            resp = handler(req)
            self.middleware.after(req, resp)
            return resp^
        except e:
            return self.errors.render_error(500, String("Internal Server Error"), req)

    def _respond[H: RouteHandler](mut self, mut handler: H, raw: List[UInt8], peer: String) raises -> Response:
        var req: Request
        try:
            req = parse_request(raw, peer)
        except:
            return self.errors.render_error(400, String("Bad Request"), Request())
        return self._pipeline(handler, req, True) if self.has_router else self._pipeline(handler, req, False)

    def _listen(self, host: String, port: Int) raises -> c_int:
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
        return sock

    def _serve_loop[H: RouteHandler](mut self, var handler: H, use_router: Bool, host: String, port: Int) raises:
        self.lifecycle.on_startup()
        try:
            var sock = self._listen(host, port)
            print("[baldr] listening on " + host + " port " + String(port)
                  + " (routes: " + String(len(self.router.entries) if use_router else 0) + ")")
            while True:
                var client = socket_accept(sock)
                if Int(client) < 0:
                    continue
                var raw = read_request(client)
                if len(raw) == 0:
                    socket_close(client)
                    continue
                var resp: Response
                var req: Request
                var parsed = True
                try:
                    req = parse_request(raw, socket_peer_ip(client))
                except:
                    req = Request()
                    parsed = False
                if parsed:
                    resp = self._pipeline(handler, req, use_router)
                else:
                    resp = self.errors.render_error(400, String("Bad Request"), req)
                var resp_bytes = resp.to_bytes()
                write_all(client, resp_bytes)
                socket_close(client)
        finally:
            self.lifecycle.on_shutdown()

    # ── The one runner ───────────────────────────────────────────────────
    def run[H: RouteHandler](
        mut self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Bind and serve forever. The route table is resolved before each
        call to the handler (405 with `Allow` / 404 on a miss) when routes
        are registered; otherwise the handler receives empty params."""
        self._serve_loop(handler^, True, host, port)

    def run[H: DispatchHandler](
        mut self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Bind and serve forever with a `DispatchHandler`: the handler routes
        by hand, so the route table is not consulted."""
        self._serve_loop(_RouteAdapter(handler^), False, host, port)

    # ── Deprecated v0.1 runners ──────────────────────────────────────────
    # Kept so every v0.1 call site still compiles. Each is the one `run`
    # with the parts passed as arguments instead of carried by the App.
    # They ignore the App's own middleware/errors/lifecycle parameters.

    def run_routes[H: RouteHandler](
        mut self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Deprecated: `run(handler)` resolves routes for a `RouteHandler`."""
        self.run(handler^, host, port)

    def run_middleware[H: DispatchHandler, *Ms: Middleware](
        self,
        var handler: H,
        var *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Deprecated: pass the stages to the constructor —
        `App(middleware=Chain((a, b))).run(handler)`."""
        self._serve_pack(_RouteAdapter(handler^), DefaultErrorHandler(), NoLifecycle(), *mws^, use_router=False, host=host, port=port)

    def run_routes_middleware[H: RouteHandler, *Ms: Middleware](
        self,
        var handler: H,
        var *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Deprecated: `App(middleware=Chain((a, b))).run(handler)`."""
        self._serve_pack(handler^, DefaultErrorHandler(), NoLifecycle(), *mws^, use_router=True, host=host, port=port)

    def run_routes_middleware_eh[H: RouteHandler, *Ms: Middleware, E2: ErrorHandler](
        self,
        var handler: H,
        var eh: E2,
        var *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Deprecated: `App(middleware=Chain((a, b)), errors=eh).run(handler)`."""
        self._serve_pack(handler^, eh^, NoLifecycle(), *mws^, use_router=True, host=host, port=port)

    def run_full[H: RouteHandler, *Ms: Middleware, E2: ErrorHandler, L2: LifecycleHooks](
        self,
        var handler: H,
        var eh: E2,
        var lifecycle: L2,
        var *mws: *Ms,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Deprecated: `App(middleware=Chain((a, b)), errors=eh,
        lifecycle=hooks).run(handler)`."""
        self._serve_pack(handler^, eh^, lifecycle^, *mws^, use_router=True, host=host, port=port)

    def _serve_pack[H: RouteHandler, *Ms: Middleware, E2: ErrorHandler, L2: LifecycleHooks](
        self,
        var handler: H,
        var eh: E2,
        var lifecycle: L2,
        var *mws: *Ms,
        use_router: Bool,
        host: String,
        port: Int,
    ) raises:
        """The v0.1 pipeline over an argument pack of middleware. Same order
        as `_pipeline`; kept only for the deprecated runners above."""
        lifecycle.on_startup()
        try:
            var sock = self._listen(host, port)
            print("[baldr] listening on " + host + " port " + String(port)
                  + " (routes: " + String(len(self.router.entries) if use_router else 0)
                  + ", mw: " + String(len(Ms)) + ")")
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
                    if not self._serve_mounted(req, resp):
                        var blocked = False
                        comptime for i in range(len(Ms)):
                            var pre = mws[i].before(req)
                            if pre.status != MW_PASS:
                                resp = pre^
                                blocked = True
                                break
                        if not blocked:
                            resp = self._route_call(handler, req, use_router)
                            comptime for j in range(len(Ms)):
                                mws[j].after(req, resp)
                except e:
                    if parsed:
                        resp = eh.render_error(500, String("Internal Server Error"), req)
                    else:
                        resp = eh.render_error(400, String("Bad Request"), req)
                var resp_bytes = resp.to_bytes()
                write_all(client, resp_bytes)
                socket_close(client)
        finally:
            lifecycle.on_shutdown()
