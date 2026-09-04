# App

`App` is the server: a static-mount table, an optional route table, an optional
asset mount, and a family of accept loops. You build one with `App()`, register
what you need, then hand your handler to one of the `run_*` methods. The one you
pick decides which features are wired in — routing, middleware, a custom error
handler, lifecycle hooks — and the compiler monomorphizes the whole stack around
your concrete types.

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
determined by the runner: the plain `run` / `run_middleware` loops call a
`DispatchHandler`; every route-aware loop (`run_routes` and up) calls a
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
    threaded in for you.) See [`run_routes`](#run_routes) for the idiom.

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

### `__init__`

```mojo
def __init__(out self)
```

Builds an empty `App`: no static mounts, an empty route table, no asset mount.
Takes no arguments — you configure it by calling the registration methods below.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| *(none)* | | | `App()` is always the starting point. |

```mojo
var app = App()
```

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

Register a route in the table consulted by the `run_routes*` loops. Sets an
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

The `run_*` loops call these internally in a fixed order (static → assets →
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

## Runners

Every `run_*` method binds a socket on `host:port` and enters an accept loop that
never returns under normal operation. They differ only in which features sit
between the socket and your handler. Pick the smallest one that covers what you
registered.

| Method | Handler trait | Routes | Middleware | Error handler | Lifecycle |
|---|---|---|---|---|---|
| [`run`](#run) | `DispatchHandler` | — | — | — | — |
| [`run_routes`](#run_routes) | `RouteHandler` | ✅ | — | — | — |
| [`run_middleware`](#run_middleware) | `DispatchHandler` | — | ✅ | — | — |
| [`run_routes_middleware`](#run_routes_middleware) | `RouteHandler` | ✅ | ✅ | — | — |
| [`run_routes_middleware_eh`](#run_routes_middleware_eh) | `RouteHandler` | ✅ | ✅ | ✅ | — |
| [`run_full`](#run_full) | `RouteHandler` | ✅ | ✅ | ✅ | ✅ |

Common to all of them:

- **Static mounts always win.** Every loop tries `dispatch_static` first, then
  the asset mount, then routes/middleware/handler.
- `host` defaults to `"0.0.0.0"`, `port` defaults to `8080`.
- The `handler` (and `eh`, `lifecycle`) arguments are taken by ownership
  (`var`) — pass them by value; transfer with `^` if you built them earlier.
- Middleware is a **variadic type parameter** `*Ms: Middleware`, monomorphized at
  compile time and iterated with `comptime for`. There is no per-request vtable.

!!! note "Variadic `[*Ms: Middleware]` in one line"
    `*Ms` is a compile-time-variadic list of types, each conforming to
    `Middleware`; `*mws: *Ms` is the matching runtime pack. You just list your
    middleware instances positionally and the compiler infers the pack. More on
    compile-time parameters in [Mojo in 5 Minutes](../mojo-primer.md).

### `run`

```mojo
def run[H: DispatchHandler](
    self,
    var handler: H,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises
```

The minimal loop. Per request: static → assets → `handler(req)`. No route table.
Any exception in the loop renders a plain-text `500 <error>`.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `DispatchHandler` | inferred | Your handler's type. |
| `handler` | `H` (owned) | — | The dispatcher instance. |
| `host` | `String` | `"0.0.0.0"` | Bind address (informational in the log; the socket binds all interfaces). |
| `port` | `Int` | `8080` | TCP port. |

```mojo
App().run(Hello(), port=8080)
```

### `run_routes`

```mojo
def run_routes[H: RouteHandler](
    self,
    var handler: H,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises
```

Adds route-table dispatch. Per request: static → assets → resolve the route table
→ `handler(req, params, name)`. A path match with the wrong method returns `405`
with an `Allow` header; an unmatched path returns `404`. If no routes were
registered, the handler is called with an empty `Params()` and an empty `name`.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `RouteHandler` | inferred | Route-aware handler type. |
| `handler` | `H` (owned) | — | Receives `(req, params, name)`. |
| `host` | `String` | `"0.0.0.0"` | Bind address. |
| `port` | `Int` | `8080` | TCP port. |

```mojo
from baldr.router import Params

@fieldwise_init
struct Api(RouteHandler, Copyable, Movable):
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        if name == "user_detail":
            return Response.text("user " + params.get("id", "?"))
        return Response.text("home\n")

def main() raises:
    var app = App()
    app.get("/",           "home")
    app.get("/users/{id}", "user_detail")
    app.run_routes(Api())
```

!!! note "Dispatch on `name`, not `req.path`"
    The Router already resolved the request before your handler runs — `name` is
    its matched route's name, so branching `if name == "user_detail":` keeps the
    `app.get(...)` table you registered as the single source of truth. No
    re-resolving, no holding a second `Router` copy. See the
    [Router & Params reference](router.md) for `Params`.

### `run_middleware`

```mojo
def run_middleware[H: DispatchHandler, *Ms: Middleware](
    self,
    var handler: H,
    *mws: *Ms,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises
```

A `DispatchHandler` wrapped in a middleware pipeline — no route table. Per
request: static → assets → each middleware's `before` (short-circuit if it
returns a non-`MW_PASS` status, e.g. `429`) → `handler(req)` → each middleware's
`after` (mutates the response in place). Middleware runs in the order you pass it.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `DispatchHandler` | inferred | Handler type. |
| `*Ms` *(param)* | `Middleware` (variadic) | inferred | Middleware types. |
| `handler` | `H` (owned) | — | The dispatcher. |
| `*mws` | `*Ms` (owned) | — | Middleware instances, positional. |
| `host` | `String` | `"0.0.0.0"` | Bind address. |
| `port` | `Int` | `8080` | TCP port. |

```mojo
from baldr.middleware.chain import SecurityHeaders, RequestLogger

app.run_middleware(
    Hello(),
    SecurityHeaders(),
    RequestLogger(),
)
```

### `run_routes_middleware`

```mojo
def run_routes_middleware[H: RouteHandler, *Ms: Middleware](
    self,
    var handler: H,
    *mws: *Ms,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises
```

Routes **and** middleware. Per request: static → assets → middleware `before`
(short-circuit) → route table (405+`Allow` / 404 on miss) → `handler(req, params, name)`
→ middleware `after`. Loop exceptions render a plain-text `500`.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `RouteHandler` | inferred | Route-aware handler. |
| `*Ms` *(param)* | `Middleware` (variadic) | inferred | Middleware types. |
| `handler` | `H` (owned) | — | Receives `(req, params, name)`. |
| `*mws` | `*Ms` (owned) | — | Middleware instances, positional. |
| `host` | `String` | `"0.0.0.0"` | Bind address. |
| `port` | `Int` | `8080` | TCP port. |

### `run_routes_middleware_eh`

```mojo
def run_routes_middleware_eh[H: RouteHandler, *Ms: Middleware, E: ErrorHandler](
    self,
    var handler: H,
    var eh: E,
    *mws: *Ms,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises
```

Same request path as `run_routes_middleware`, but any exception is rendered via
`eh.render_error(500, message, req)` instead of the plain-text fallback. Use
`JsonErrorHandler()` for API apps or `HtmlErrorHandler()` for browser apps (see
[Config & Error Handling](../guide/config-errors.md)), or conform your own struct
to `ErrorHandler`. A request that fails to even parse returns a plain
`400 bad request`.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `RouteHandler` | inferred | Route-aware handler. |
| `*Ms` *(param)* | `Middleware` (variadic) | inferred | Middleware types. |
| `E` *(param)* | `ErrorHandler` | inferred | Error-handler type. |
| `handler` | `H` (owned) | — | Receives `(req, params, name)`. |
| `eh` | `E` (owned) | — | Renders `500`s. Note: `eh` comes **before** `*mws`. |
| `*mws` | `*Ms` (owned) | — | Middleware instances, positional. |
| `host` | `String` | `"0.0.0.0"` | Bind address. |
| `port` | `Int` | `8080` | TCP port. |

```mojo
from baldr.errors import JsonErrorHandler

app.run_routes_middleware_eh(
    Api(),
    JsonErrorHandler(),
    SecurityHeaders(),
)
```

!!! note "Argument order: `eh` before the middleware pack"
    Because a variadic `*mws` has to come last among the positional runtime
    arguments, `eh` sits **between** `handler` and `*mws`. Read the signature
    literally: handler, then error handler, then all your middleware.

### `run_full`

```mojo
def run_full[H: RouteHandler, *Ms: Middleware, E: ErrorHandler, L: LifecycleHooks](
    self,
    var handler: H,
    var eh: E,
    var lifecycle: L,
    *mws: *Ms,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises
```

The capstone: routes + middleware + error handler + lifecycle hooks.
`lifecycle.on_startup()` runs once before the socket binds; `lifecycle.on_shutdown()`
runs in a `finally` when the loop unwinds (e.g. Ctrl-C). The per-request path is
identical to `run_routes_middleware_eh`.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `H` *(param)* | `RouteHandler` | inferred | Route-aware handler. |
| `*Ms` *(param)* | `Middleware` (variadic) | inferred | Middleware types. |
| `E` *(param)* | `ErrorHandler` | inferred | Error-handler type. |
| `L` *(param)* | `LifecycleHooks` | inferred | Lifecycle-hooks type. |
| `handler` | `H` (owned) | — | Receives `(req, params, name)`. |
| `eh` | `E` (owned) | — | Renders `500`s. |
| `lifecycle` | `L` (owned) | — | `on_startup` / `on_shutdown` hooks. |
| `*mws` | `*Ms` (owned) | — | Middleware instances, positional. |
| `host` | `String` | `"0.0.0.0"` | Bind address. |
| `port` | `Int` | `8080` | TCP port. |

```mojo
app.run_full(
    Api(),
    JsonErrorHandler(),
    MyLifecycle(),
    SecurityHeaders(),
    RequestLogger(),
)
```

!!! warning "The accept loops are single-threaded and blocking"
    Every `run_*` method is one `accept → read → dispatch → write → close` loop
    on a single thread. There's no keep-alive and no concurrency inside a single
    runner — a slow handler blocks the next request. Parallelism today comes from
    the prefork worker pool (a separate primitive), not from these loops. This is
    pre-alpha; treat the runners as the correctness-first baseline they are.

---

## See also

- [Request & Response](request-response.md) — the `Request` your handler receives and the `Response.text/html/json/redirect` builders.
- [Router & Params](router.md) — building the route table and reading `params`.
- [Routing & Path Params](../tutorial/routing.md) — the tutorial walkthrough.
- [Middleware](../tutorial/middleware.md) — writing `before`/`after` hooks.
- [Config & Error Handling](../guide/config-errors.md) — `ErrorHandler`, `JsonErrorHandler`, `HtmlErrorHandler`.
