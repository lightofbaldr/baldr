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
`lifecycle.on_startup()` runs once before binding, `on_shutdown()` once in
the parent after a graceful stop. SIGTERM/SIGINT drain the active connection;
prefork workers are supervised and replaced unless they enter a crash loop.
`handle(handler, req)` runs that same pipeline on one in-memory request,
which is how you test an app without a socket.

Why parameters and not a builder chain: Mojo 1.0 cannot store a function or
a trait object in a struct field, but it can store a concrete `M` / `E` / `L`
and a `Chain[*Ms]` holds its stages in a `Tuple` — so the parts live on the
App as lvalues, which is also what lets middleware keep state (`mut self`).

The six `run_*` runners of v0.1 remain as deprecated wrappers; every call
that compiled before still compiles and behaves the same.
"""

from std.ffi import c_int
from std.pathlib import Path
from std.time import perf_counter_ns, sleep

from .http import (
    socket_create, socket_reuseaddr, make_sockaddr_in,
    socket_bind, socket_listen, socket_accept, socket_close,
    socket_recv_timeout,
    read_request, read_request_from, write_all, socket_peer_ip, wants_keep_alive,
    process_fork, process_getpid, process_kill, process_waitpid,
    process_waitpid_nohang, process_exit, signal_block, signal_pending,
    SIGNAL_TERM, SIGNAL_KILL,
    READ_TIMEOUT_SECS, KEEPALIVE_IDLE_SECS,
)
from .streaming import ResponseStream
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


trait StreamHandler(Movable, Deinitable):
    """A handler that writes its response incrementally. `App.run()` /
    `serve_connection()` hand it the parsed request and a `ResponseStream`
    bound to the client socket; the handler calls `out.start(...)`, then
    `out.write(...)` / `out.send_event(...)` as data becomes available, and
    `out.finish()`. The App finishes an unfinished stream on return, renders
    the error handler's 500 if the handler raises before `start()`, and
    closes the connection if it raises after. Middleware `before` hooks run
    (and may short-circuit with a buffered response); `after` hooks do not —
    the headers are already on the wire. Static and asset mounts still win."""
    def __call__(mut self, req: Request, mut out: ResponseStream) raises: ...


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

    # ── One connection ───────────────────────────────────────────────────
    # A connection is served as a keep-alive loop: read a request (15 s
    # budget for the first, KEEPALIVE_IDLE_SECS for each next one), run the
    # pipeline, write the response with the `Connection:` header the loop
    # decided on, and go again while the client wants to (HTTP/1.1 default,
    # HTTP/1.0 opt-in). The caller owns and closes the descriptor.

    def _read_one(self, fd: c_int, first: Bool, mut pending: List[UInt8], mut req: Request) -> Int:
        """0 = connection done (EOF / timeout / oversize), 1 = parsed into
        `req`, 2 = bytes arrived but did not parse. `pending` carries any
        pipelined bytes between calls."""
        var raw = read_request_from(fd, pending, timeout_secs=READ_TIMEOUT_SECS if first else KEEPALIVE_IDLE_SECS)
        if len(raw) == 0:
            return 0
        try:
            req = parse_request(raw, socket_peer_ip(fd))
            return 1
        except:
            return 2

    def _serve_connection_buffered[H: RouteHandler](mut self, fd: c_int, mut handler: H, use_router: Bool) raises:
        var first = True
        var pending = List[UInt8]()
        while True:
            var req = Request()
            var state = self._read_one(fd, first, pending, req)
            first = False
            if state == 0:
                return
            if state == 2:
                var bad = self.errors.render_error(400, String("Bad Request"), req)
                var bad_bytes = bad.to_bytes(False)
                write_all(fd, bad_bytes)
                return
            var keep = wants_keep_alive(req)
            var resp = self._pipeline(handler, req, use_router)
            var resp_bytes = resp.to_bytes(keep)
            write_all(fd, resp_bytes)
            if not keep:
                return

    def serve_connection[H: RouteHandler](mut self, fd: c_int, mut handler: H) raises:
        """Serve every request on an already-connected socket with the full
        pipeline (route table resolved), honouring keep-alive; returns when
        the client is done. Does not close `fd`. `run()` calls this per
        accepted connection; tests call it on one end of a socket pair."""
        self._serve_connection_buffered(fd, handler, True)

    def serve_connection[H: DispatchHandler](mut self, fd: c_int, mut handler: H) raises:
        """`serve_connection` for a `DispatchHandler` (route table ignored)."""
        var first = True
        var pending = List[UInt8]()
        while True:
            var req = Request()
            var state = self._read_one(fd, first, pending, req)
            first = False
            if state == 0:
                return
            if state == 2:
                var bad = self.errors.render_error(400, String("Bad Request"), req)
                var bad_bytes = bad.to_bytes(False)
                write_all(fd, bad_bytes)
                return
            var keep = wants_keep_alive(req)
            var resp = self.handle(handler, req)
            var resp_bytes = resp.to_bytes(keep)
            write_all(fd, resp_bytes)
            if not keep:
                return

    def serve_connection[H: StreamHandler](mut self, fd: c_int, mut handler: H) raises:
        """`serve_connection` for a `StreamHandler`: mounts and middleware
        `before` still answer with buffered responses; otherwise the handler
        writes the response itself through a `ResponseStream` on `fd`. The
        connection stays open for the next request only if the handler
        finished its stream cleanly and the client wants keep-alive."""
        var first = True
        var pending = List[UInt8]()
        while True:
            var req = Request()
            var state = self._read_one(fd, first, pending, req)
            first = False
            if state == 0:
                return
            if state == 2:
                var bad = self.errors.render_error(400, String("Bad Request"), req)
                var bad_bytes = bad.to_bytes(False)
                write_all(fd, bad_bytes)
                return
            var keep = wants_keep_alive(req)
            var buffered = Response()
            var have_buffered = self._serve_mounted(req, buffered)
            if not have_buffered:
                try:
                    var pre = self.middleware.before(req)
                    if pre.status != MW_PASS:
                        buffered = pre^
                        have_buffered = True
                except e:
                    buffered = self.errors.render_error(500, String("Internal Server Error"), req)
                    have_buffered = True
            if have_buffered:
                var out_bytes = buffered.to_bytes(keep)
                write_all(fd, out_bytes)
                if not keep:
                    return
                continue
            var out = ResponseStream(fd)
            var broke = False
            try:
                handler(req, out)
            except e:
                if not out.started():
                    var err = self.errors.render_error(500, String("Internal Server Error"), req)
                    var err_bytes = err.to_bytes(False)
                    write_all(fd, err_bytes)
                    return
                broke = True
            if not out.finished():
                try:
                    out.finish()
                except:
                    broke = True
            if broke or not keep:
                return

    # ── The accept loop + prefork pool ───────────────────────────────────
    def _remove_live_pid(self, mut live: List[Int], pid: Int) -> Bool:
        for i in range(len(live)):
            if live[i] == pid:
                _ = live.pop(i)
                return True
        return False

    def _stop_workers(self, mut live: List[Int], grace_secs: Int):
        """Ask workers to drain, then kill only those past the deadline."""
        for i in range(len(live)):
            _ = process_kill(live[i], SIGNAL_TERM)

        var grace = grace_secs if grace_secs > 0 else 0
        var deadline = perf_counter_ns() + grace * 1_000_000_000
        while len(live) > 0 and perf_counter_ns() < deadline:
            var status: c_int = 0
            var reaped = Int(process_waitpid_nohang(-1, status))
            while reaped > 0:
                _ = self._remove_live_pid(live, reaped)
                status = 0
                reaped = Int(process_waitpid_nohang(-1, status))
            if len(live) > 0:
                sleep(0.05)

        # At the deadline, preserve the exact live set: these are the only
        # processes that may receive SIGKILL.
        for i in range(len(live)):
            _ = process_kill(live[i], SIGNAL_KILL)
        while len(live) > 0:
            var status: c_int = 0
            var reaped = Int(process_waitpid(-1, status))
            if reaped <= 0:
                break
            _ = self._remove_live_pid(live, reaped)

    def _spawn_workers(
        self,
        workers: Int,
        host: String,
        port: Int,
        routes: String,
        grace_secs: Int,
    ) raises -> Bool:
        """Single-process mode returns True at once. Prefork mode forks
        `workers` children that each return True (serve), while the parent
        supervises them and returns False after shutdown. Each worker inherits
        this App and the handler by fork, so per-worker state diverges by
        design — shared state belongs in baldr.db or baldr.queue."""
        if workers <= 1:
            print("[baldr] listening on " + host + " port " + String(port) + " (routes: " + routes + ")")
            return True
        print("[baldr] prefork: " + String(workers) + " workers on " + host + " port "
              + String(port) + " (parent pid " + String(Int(process_getpid()))
              + ", routes: " + routes + ")")
        var live = List[Int]()
        var worker_id = 0
        for i in range(workers):
            var pid = Int(process_fork())
            if pid == 0:
                print("[baldr] worker " + String(i) + " pid " + String(Int(process_getpid())) + " ready")
                return True
            elif pid > 0:
                live.append(pid)
                worker_id += 1
            else:
                self._stop_workers(live, grace_secs)
                raise Error(String("baldr: fork() failed"))

        var respawn_ns = List[Int]()
        var crash_loop = False
        while len(live) > 0:
            if signal_pending():
                print("[baldr] shutdown requested; draining workers")
                break

            var status: c_int = 0
            var reaped = Int(process_waitpid_nohang(-1, status))
            while reaped > 0:
                if self._remove_live_pid(live, reaped):
                    var now = perf_counter_ns()
                    while len(respawn_ns) > 0 and now - respawn_ns[0] > 10_000_000_000:
                        _ = respawn_ns.pop(0)
                    if len(respawn_ns) >= 5:
                        crash_loop = True
                        break

                    # Linear 100–500 ms backoff keeps a flapping worker from
                    # turning the supervisor itself into a hot loop.
                    sleep(Float64(len(respawn_ns) + 1) * 0.1)
                    var pid = Int(process_fork())
                    if pid == 0:
                        print("[baldr] worker " + String(worker_id) + " pid " + String(Int(process_getpid())) + " ready")
                        return True
                    if pid < 0:
                        self._stop_workers(live, grace_secs)
                        raise Error(String("baldr: fork() failed during worker respawn"))
                    live.append(pid)
                    respawn_ns.append(perf_counter_ns())
                    worker_id += 1
                status = 0
                reaped = Int(process_waitpid_nohang(-1, status))
            if crash_loop:
                print("[baldr] worker crash loop; giving up")
                break
            sleep(0.25)

        self._stop_workers(live, grace_secs)
        if crash_loop:
            raise Error(String("baldr: worker crash loop"))
        return False

    def _serve_loop[H: RouteHandler](mut self, var handler: H, use_router: Bool, host: String, port: Int, workers: Int, grace_secs: Int) raises:
        if not signal_block():
            raise Error(String("baldr: failed to block SIGTERM/SIGINT"))
        var sock: c_int = -1
        self.lifecycle.on_startup()
        try:
            sock = self._listen(host, port)
            if not socket_recv_timeout(sock, 1):
                raise Error(String("baldr: failed to set accept timeout"))
            var routes = String(len(self.router.entries) if use_router else 0)
            if self._spawn_workers(workers, host, port, routes, grace_secs):
                while True:
                    var client = socket_accept(sock)
                    if Int(client) < 0:
                        if signal_pending():
                            break
                        continue
                    self._serve_connection_buffered(client, handler, use_router)
                    socket_close(client)
                    if signal_pending():
                        break
                if workers > 1:
                    socket_close(sock)
                    sock = c_int(-1)
                    process_exit(0)
        finally:
            try:
                self.lifecycle.on_shutdown()
            finally:
                if Int(sock) >= 0:
                    socket_close(sock)

    def _serve_loop_stream[H: StreamHandler](mut self, var handler: H, host: String, port: Int, workers: Int, grace_secs: Int) raises:
        if not signal_block():
            raise Error(String("baldr: failed to block SIGTERM/SIGINT"))
        var sock: c_int = -1
        self.lifecycle.on_startup()
        try:
            sock = self._listen(host, port)
            if not socket_recv_timeout(sock, 1):
                raise Error(String("baldr: failed to set accept timeout"))
            if self._spawn_workers(workers, host, port, String("stream"), grace_secs):
                while True:
                    var client = socket_accept(sock)
                    if Int(client) < 0:
                        if signal_pending():
                            break
                        continue
                    self.serve_connection(client, handler)
                    socket_close(client)
                    if signal_pending():
                        break
                if workers > 1:
                    socket_close(sock)
                    sock = c_int(-1)
                    process_exit(0)
        finally:
            try:
                self.lifecycle.on_shutdown()
            finally:
                if Int(sock) >= 0:
                    socket_close(sock)

    # ── The one runner ───────────────────────────────────────────────────
    def run[H: RouteHandler](
        mut self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
        workers: Int = 1,
        grace_secs: Int = 5,
    ) raises:
        """Bind and serve forever. The route table is resolved before each
        call to the handler (405 with `Allow` / 404 on a miss) when routes
        are registered; otherwise the handler receives empty params.
        Connections are kept alive per `wants_keep_alive`. `workers > 1`
        preforks that many processes sharing the listening socket, each
        running the full pipeline. SIGTERM/SIGINT drain active connections;
        `grace_secs` bounds the drain before remaining workers are killed."""
        self._serve_loop(handler^, True, host, port, workers, grace_secs)

    def run[H: DispatchHandler](
        mut self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
        workers: Int = 1,
        grace_secs: Int = 5,
    ) raises:
        """Bind and serve forever with a `DispatchHandler`: the handler routes
        by hand, so the route table is not consulted. `workers > 1` preforks.
        `grace_secs` bounds graceful worker drain on shutdown."""
        self._serve_loop(_RouteAdapter(handler^), False, host, port, workers, grace_secs)

    def run[H: StreamHandler](
        mut self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
        workers: Int = 1,
        grace_secs: Int = 5,
    ) raises:
        """Bind and serve forever with a `StreamHandler`: each request gets a
        `ResponseStream` on the client socket (chunked, SSE-capable). Mounts
        and middleware `before` still apply; `workers > 1` preforks.
        `grace_secs` bounds graceful worker drain on shutdown."""
        self._serve_loop_stream(handler^, host, port, workers, grace_secs)

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
