# App

`App` is the server: a static-mount table, an optional route table, an optional
asset mount, and the three optional parts of the request pipeline — middleware,
an error handler, lifecycle hooks — carried as **type parameters** with defaults.
`App()` is the bare server; pass a part to the constructor to add it, register
what you need, then hand your handler to the one `run`. The compiler
monomorphizes the whole stack around your concrete types.

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct Hello(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        return Response.text("hi\n")

def main() raises:
    var app = App()
    app.static("/static", "./static")
    app.run(Hello(), port=8080)
```

!!! note "`[H]`, `mut self` — quick Mojo reminders"
    baldr APIs take `String`, but bare string literals convert automatically —
    no `String(...)` wraps needed. The `[H: DispatchHandler]` on `run` is a
    compile-time parameter (usually inferred), and handlers take `mut self` so
    they can carry state between requests. All of these are covered in
    [Mojo in 5 Minutes](../mojo-primer.md).

`App` is defined in `src/baldr/app.mojo` alongside the two dispatch traits and
`StaticMount`.

---

## Traits

A handler is a struct you conform to one of two traits. Which trait you use is
determined by what you hand to `run`: a `DispatchHandler` routes by hand and the
route table is ignored; a `RouteHandler` gets the table resolved first and is called as a
`RouteHandler`.

### `DispatchHandler`

```mojo
trait DispatchHandler(Movable, ImplicitlyDeletable):
    def __call__(mut self, req: Request) raises -> Response: ...
```

| Member | Signature | Notes |
|---|---|---|
| `__call__` | `def __call__(mut self, req: Request) raises -> Response` | Called once per request. `mut self` lets the handler carry per-server state (caches, counters, rate limiters) across requests. |

### `RouteHandler`

```mojo
trait RouteHandler(Movable, ImplicitlyDeletable):
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response: ...
```

| Member | Signature | Notes |
|---|---|---|
| `__call__` | `def __call__(mut self, req: Request, params: Params, name: String) raises -> Response` | Called only after the route table resolves the request. `params` carries the extracted path params (empty on a no-param route); `name` is the matched route's NAME (empty when no route matched). |

!!! note "Branch on the matched route `name` (previously a rough edge — fixed in this version)"
    `RouteHandler.__call__` receives the matched route's `name` as a third
    argument, so you branch on it directly — `if name == "user_detail":` —
    instead of re-inspecting `req.path` / `req.method` or re-resolving against
    a copy of the `Router`. The route table you registered with `app.get(...)`
    etc. stays the single source of truth. (Mojo 1.0 still has no storable
    function pointers, so this name-dispatch lives in the handler body rather
    than binding each route to its own callback — but the resolved name is now
    threaded in for you.) See [`run`](#run) for the idiom.

---

## `StaticMount`

A plain data record: one URL prefix bound to one filesystem directory. You rarely
construct these directly — [`static`](#static) appends one for you.

```mojo
struct StaticMount(Copyable, Movable):
    var prefix: String
    var dir: String

    def __init__(out self, prefix: String, dir: String)
```

| Field | Type | Meaning |
|---|---|---|
| `prefix` | `String` | URL prefix, e.g. `/static`. Matched on a path-segment boundary. |
| `dir` | `String` | Filesystem directory served under that prefix. |

---

## Constructor

```mojo
struct App[
    M: Middleware = NoMiddleware,
    E: ErrorHandler = DefaultErrorHandler,
    L: LifecycleHooks = NoLifecycle,
](Movable)

def __init__(out self)                                        # every part defaulted
def __init__(out self, var middleware: M)
def __init__(out self, var middleware: M, var errors: E)
def __init__(out self, var middleware: M, var errors: E, var lifecycle: L)
def __init__(out self, *, var errors: E)                      # keyword-only forms
def __init__(out self, *, var lifecycle: L)
def __init__(out self, *, var errors: E, var lifecycle: L)
def __init__(out self, *, var middleware: M, var lifecycle: L)
```

The parts are type parameters; you never spell them — the compiler infers `M`,
`E` and `L` from the values you pass, and a part you leave out is
default-constructed (`NoMiddleware`, `DefaultErrorHandler`, `NoLifecycle`; any
built-in handler works as a default because they are all `Defaultable`).

| Part | Trait | Default | What it does |
|---|---|---|---|
| `middleware` | `Middleware` | `NoMiddleware` | One stage, or several as `Chain((a, b, c))`. Runs `before` the handler (may short-circuit) and `after` it. Stages are fields of the App, so they may keep state (`mut self`). |
| `errors` | `ErrorHandler` | `DefaultErrorHandler` | Renders `400 Bad Request` for an unparseable request and `500 Internal Server Error` when the handler raises. `JsonErrorHandler` / `HtmlErrorHandler` are built in. |
| `lifecycle` | `LifecycleHooks` | `NoLifecycle` | `on_startup()` once before the socket binds, `on_shutdown()` once after the loop exits. |

```mojo
var app = App()                                              # bare
var api = App(errors=JsonErrorHandler())                     # JSON errors
var site = App(
    middleware=Chain((SecurityHeaders(), RequestLogger())),
    errors=HtmlErrorHandler(),
    lifecycle=MyHooks(),
)
var typed = App[E=JsonErrorHandler]()                        # a default-constructed part by type
```

The parts are public fields (`app.middleware`, `app.errors`, `app.lifecycle`), so a
test can read a stage's state after a request.

---

## Registration

These methods are pure data mutations — call them before a `run_*` method to
populate the mount/route/asset tables. All of them take `mut self`.

### `static`

```mojo
def static(mut self, prefix: String, dir: String)
```

Serve everything under `dir` at URL `prefix/`. Appends a `StaticMount`. Static
mounts are consulted **first** on every request and win over assets, routes, and
your handler.

| Parameter | Type | Notes |
|---|---|---|
| `prefix` | `String` | URL prefix, matched on a segment boundary (`/static` matches `/static` and `/static/…` but **not** `/static-secret`). |
| `dir` | `String` | Directory on disk. Files are resolved with a path-traversal-safe join. |

```mojo
app.static("/static", "./public")
```

### `route`

```mojo
def route(mut self, method: String, pattern: String, name: String)
```

Register a route in the table `run()` / `handle()` resolve for a `RouteHandler`. Sets an
internal `has_router` flag so the loop knows to resolve before dispatch. Patterns
support `{param}` segments, e.g. `/users/{id}`.

| Parameter | Type | Notes |
|---|---|---|
| `method` | `String` | HTTP method, e.g. `"GET"`. |
| `pattern` | `String` | Route pattern; `{name}` segments become path params. |
| `name` | `String` | The route's name — passed to your handler's `__call__` as `name`; branch on it directly (`if name == "..."`). |

### `get` / `post` / `put` / `delete` / `patch`

```mojo
def get(mut self, pattern: String, name: String)
def post(mut self, pattern: String, name: String)
def put(mut self, pattern: String, name: String)
def delete(mut self, pattern: String, name: String)
def patch(mut self, pattern: String, name: String)
```

Method-specific shorthands for `route`. Each forwards to
`route("GET", ...)` etc.

| Parameter | Type | Notes |
|---|---|---|
| `pattern` | `String` | Route pattern with optional `{param}` segments. |
| `name` | `String` | Route name to dispatch on. |

```mojo
app.get("/",            "home")
app.get("/users/{id}",  "user_detail")
app.post("/users",      "user_create")
```

!!! note "There's no `head` shorthand on `App` (yet)"
    `App` exposes `get/post/put/delete/patch`, but not `head` — even though the
    underlying `Router` has a `head()` method. To register a HEAD route today,
    call `app.route("HEAD", pattern, name)` directly. (`GET` static
    mounts already answer `HEAD` on their own.)

### `assets`

```mojo
def assets(mut self, var manifest: AssetManifest, url_prefix: String = "/static")
```

Register an asset-aware mount backed by an `AssetManifest` (see
[Static Files & Assets](../tutorial/static.md)). Manifest URLs — hashed filenames
like `/static/app.abc123.js` — are served from the manifest's cached bytes with
aggressive immutable caching and `ETag` / `If-None-Match` support. The `manifest`
argument is taken by ownership (`var`), so pass it with `^`.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `manifest` | `AssetManifest` (owned) | — | The built manifest. Transferred in with `^`. |
| `url_prefix` | `String` | `"/static"` | Documented prefix for the mount. |

!!! warning "`url_prefix` is currently accepted but not applied"
    As of this build, `assets(...)` stores the manifest and sets `has_assets`,
    but it does **not** retain `url_prefix` — asset dispatch matches purely on
    whether the request path is a known manifest URL (`manifest.has_url(path)`).
    Passing a non-default `url_prefix` has no effect yet. Register your assets
    under whatever prefix the manifest itself was built with.

```mojo
app.assets(manifest^)
```

---

## Dispatch helpers

`run()` / `handle()` call these internally in a fixed order (static → assets →
routes/handler). They're public so you can compose your own loop, but note their
**raise-to-fall-through** contract: a miss raises, and the caller catches it to
try the next layer.

### `dispatch_static`

```mojo
def dispatch_static(self, req: Request) raises -> Response
```

Resolve `req` against the static-mount table. Returns a file `Response` on a
match (or a `405` if the method isn't `GET`/`HEAD`). **Raises** if no mount
matches — callers catch and fall through.

### `dispatch_assets`

```mojo
def dispatch_assets(self, req: Request) raises -> Response
```

Serve an asset from the manifest. Returns a `200` with immutable caching headers,
or a cheap `304` when `If-None-Match` matches the asset hash. **Raises** if no
asset mount is registered or the path isn't a manifest URL.

!!! note "Raising is the control flow here, not an error"
    Both helpers signal "not mine" by raising, and the accept loops wrap each in
    a `try/except` to chain to the next layer. If you call them yourself, wrap
    them the same way — a raise means "fall through," not "the request failed."

---

## `run`

```mojo
def run[H: RouteHandler](mut self, var handler: H, host: String = "0.0.0.0", port: Int = 8080, workers: Int = 1) raises
def run[H: DispatchHandler](mut self, var handler: H, host: String = "0.0.0.0", port: Int = 8080, workers: Int = 1) raises
```

Binds a socket on `host:port` and serves forever. There is one runner; the
overload is picked by your handler's trait:

- a **`RouteHandler`** has the route table resolved first — a path match with the
  wrong method returns `405` with an `Allow` header, an unmatched path returns
  `404`, and on a match the handler receives `(req, params, name)`. With no routes
  registered it is called with empty `Params()` and an empty `name`;
- a **`DispatchHandler`** routes by hand: it is called as `handler(req)` and the
  route table is ignored.

Per request, in order: static mounts → asset mount → `middleware.before` (a
non-`MW_PASS` response ends the request there; the handler and every `after`
hook are skipped) → route table → handler → `middleware.after` → and if
anything raised, `errors.render_error(500, "Internal Server Error", req)`. A
request that does not parse gets `errors.render_error(400, "Bad Request", ...)`.
`lifecycle.on_startup()` runs before the bind, `on_shutdown()` in a `finally`
when the loop unwinds (e.g. Ctrl-C).

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `RouteHandler` or `DispatchHandler` | inferred | Your handler's type. |
| `handler` | `H` (owned) | — | Transferred in with `^` if you built it earlier. |
| `host` | `String` | `"0.0.0.0"` | Bind address (informational in the log; the socket binds all interfaces). |
| `port` | `Int` | `8080` | TCP port. |
| `workers` | `Int` | `1` | `N > 1` preforks `N` processes sharing the socket; each runs the full pipeline. See [Concurrency](../guide/concurrency.md). |

```mojo
var app = App(middleware=Chain((SecurityHeaders(), RequestLogger())), errors=JsonErrorHandler())
app.get("/",           "home")
app.get("/users/{id}", "user_detail")
app.run(Api(), port=8080)
```

## `handle`

```mojo
def handle[H: RouteHandler](mut self, mut handler: H, req: Request) raises -> Response
def handle[H: DispatchHandler](mut self, mut handler: H, req: Request) raises -> Response
```

The same pipeline on one in-memory `Request`, no socket: mounts, middleware,
route table, handler, error handler. This is how you test an app — build the
request with `baldr.testing.get/post/...`, call `handle`, assert on the
`Response`; the handler is borrowed `mut`, so you can inspect its state after.

```mojo
from baldr.testing import get

var app = App(middleware=Chain((Blocker(403), Counter(0, 0))))
var h = Api()
var resp = app.handle(h, get("/blocked"))
# resp.status == 403, app.middleware.stages[1].befores == 0
```

!!! warning "The accept loop is single-threaded and blocking"
    `run` is one `accept → read → dispatch → write → close` loop on a single
    thread per worker. There is no keep-alive and no concurrency inside one
    worker — a slow handler blocks that worker's next request. Parallelism
    comes from `workers=N`: a prefork pool where every worker runs this same
    pipeline.

## Deprecated runners

The six v0.1 runners still compile and behave as they did; each is `run` with
the parts passed as arguments instead of carried by the App. They ignore the
App's own `middleware` / `errors` / `lifecycle` and will be removed at v0.2.

| Deprecated | Write instead |
|---|---|
| `run_routes(h)` | `run(h)` |
| `run_middleware(h, a, b)` | `App(middleware=Chain((a, b))).run(h)` |
| `run_routes_middleware(h, a, b)` | `App(middleware=Chain((a, b))).run(h)` |
| `run_routes_middleware_eh(h, eh, a, b)` | `App(middleware=Chain((a, b)), errors=eh).run(h)` |
| `run_full(h, eh, hooks, a, b)` | `App(middleware=Chain((a, b)), errors=eh, lifecycle=hooks).run(h)` |

---

## See also

- [Request & Response](request-response.md) — the `Request` your handler receives and the `Response.text/html/json/redirect` builders.
- [Router & Params](router.md) — building the route table and reading `params`.
- [Routing & Path Params](../tutorial/routing.md) — the tutorial walkthrough.
- [Middleware](../tutorial/middleware.md) — writing `before`/`after` hooks.
- [Config & Error Handling](../guide/config-errors.md) — `ErrorHandler`, `JsonErrorHandler`, `HtmlErrorHandler`.
