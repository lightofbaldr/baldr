# The Handler Trait

Everything in baldr flows through one idea: **your app is a struct, and that struct is a handler.** Not a function you register, not a decorator over an interpreter — a value with fields, that the server holds onto and calls once per request.

This page is the conceptual core. Once the handler trait clicks, the rest of baldr is just "which `run_*` method do I call, and what does it wire in."

## Two traits, one shape

baldr defines exactly two handler traits in `baldr.app`. They differ by one parameter.

```mojo
trait DispatchHandler(Movable, ImplicitlyDeletable):
    def __call__(mut self, req: Request) raises -> Response: ...

trait RouteHandler(Movable, ImplicitlyDeletable):
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response: ...
```

- **`DispatchHandler`** sees the raw request and answers. It *is* the whole router — you branch on `req.method` and `req.path` yourself.
- **`RouteHandler`** is called *after* baldr's route table has already matched the path, so it also receives the extracted path `params` (e.g. `{id}` from `/users/{id}`) and the matched route's `name` (empty when no route matched). baldr does the matching and the 404/405 bookkeeping; you branch on `name` to dispatch — `if name == "note_show":` — so the route table you registered (`app.get("/notes/{id}", "note_show")`) stays the single source of truth instead of re-deriving it from `req.path`.

That's the only difference. Same `mut self`, same `Request`, same `raises -> Response`. You pick the trait by picking a `run_*` method (the table below) — the method's compile-time bound decides which `__call__` signature the compiler expects of you.

!!! note "What are `Movable` and `ImplicitlyDeletable`? (they're Mojo, not baldr)"
    They're built-in Mojo traits in the parent list. They let baldr *own* your handler value — move it into the accept loop and destroy it cleanly on exit. You never implement them by hand; conforming your struct with `@fieldwise_init` plus `Copyable, Movable` covers it. See the [Mojo primer](../mojo-primer.md).

## Why a struct, and why `mut self`

Here's the load-bearing part. A handler is a struct because **a struct owns its state between requests.**

In FastAPI you reach for module globals or a dependency-injection container to hold a cache or a rate limiter. In baldr those live as *fields on your handler*, initialized once, reused on every request:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct Counter(DispatchHandler, Copyable, Movable):
    var hits: Int          # survives across requests
    var greeting: String   # loaded once, read every request

    def __call__(mut self, req: Request) raises -> Response:
        self.hits += 1     # mutate our own state as we serve
        return Response.text(
            self.greeting + " #" + String(self.hits) + "\n"
        )

def main() raises:
    App().run(Counter(0, "hello"), port=8080)
```

Every request calls `Counter.__call__`, and every request increments the *same* `hits` field. That is why the signature is `mut self` and not plain `self`: the handler is allowed to mutate itself while it serves. A cache warms, a counter climbs, a rate limiter records the hit time — all in fields, no globals.

!!! note "`mut self` is Mojo's 'this method may mutate me'"
    In Mojo, `self` is borrowed read-only by default; `mut self` says the method can change the value's fields. Same idea as a Python method that assigns to `self.x`, but the compiler tracks it. See [ownership in the primer](../mojo-primer.md).

What belongs in those fields? Anything you'd otherwise make global:

- a template loader (parse once at construction, render per request)
- a rate limiter holding per-key hit times
- an in-memory counter or metrics tally
- a database handle or connection pool
- a preloaded config, an asset manifest, a warmed cache

The handler is your application object. `run(...)` just calls it in a loop.

!!! tip "State is set up in the constructor"
    `@fieldwise_init` gives you `Counter(0, "hello")` — one argument per field, in declaration order (bare string literals convert to `String` automatically). Do heavier one-time setup (open a file, parse templates) in a hand-written `__init__(out self)` and stash the result in a field. It runs once, before the socket binds.

## The `run_*` family

baldr does not have one `run`. It has **six**, and each one bolts on a different optional feature. You call exactly one, and its compile-time signature tells you which handler trait to conform to and what else to pass.

| Method | Handler trait | Adds | You get |
|---|---|---|---|
| `run` | `DispatchHandler` | — | bare accept loop; you route by hand |
| `run_routes` | `RouteHandler` | route table | path matching + `params`, auto 404/405 |
| `run_middleware` | `DispatchHandler` | middleware | `before`/`after` pipeline, no routing |
| `run_routes_middleware` | `RouteHandler` | routes + middleware | both of the above |
| `run_routes_middleware_eh` | `RouteHandler` | + error handler | custom 500 rendering (JSON/HTML) |
| `run_full` | `RouteHandler` | + lifecycle hooks | startup/shutdown + everything above |

Static file mounts (`app.static(...)`) and asset mounts (`app.assets(...)`) work with **all six** — they're pure data, resolved before your handler on every path.

### Reading the signatures

Here are the real signatures, trimmed to the parts you pass. Note the split: `[...]` is compile-time, `(...)` is runtime.

```mojo
def run[H: DispatchHandler](
    self, var handler: H,
    host: String = "0.0.0.0", port: Int = 8080,
) raises

def run_routes[H: RouteHandler](
    self, var handler: H,
    host: String = "0.0.0.0", port: Int = 8080,
) raises

def run_middleware[H: DispatchHandler, *Ms: Middleware](
    self, var handler: H, *mws: *Ms,
    host: String = "0.0.0.0", port: Int = 8080,
) raises

def run_routes_middleware[H: RouteHandler, *Ms: Middleware](
    self, var handler: H, *mws: *Ms,
    host: String = "0.0.0.0", port: Int = 8080,
) raises

def run_routes_middleware_eh[H: RouteHandler, *Ms: Middleware, E: ErrorHandler](
    self, var handler: H, var eh: E, *mws: *Ms,
    host: String = "0.0.0.0", port: Int = 8080,
) raises

def run_full[H: RouteHandler, *Ms: Middleware, E: ErrorHandler, L: LifecycleHooks](
    self, var handler: H, var eh: E, var lifecycle: L, *mws: *Ms,
    host: String = "0.0.0.0", port: Int = 8080,
) raises
```

!!! note "`[H: DispatchHandler]` and `*Ms: Middleware` are compile-time params"
    The `[...]` list holds types resolved at build time — `H` is your handler's type, `*Ms` is the variadic pack of middleware types. Because they're monomorphized in, there is **no per-request vtable lookup**; the dispatch is baked into the binary. You almost never write the brackets — the compiler infers `H` and `*Ms` from the values you pass. See [square-bracket params in the primer](../mojo-primer.md).

The important runtime detail: **the fixed arguments come before the variadic `*mws`.** So the error handler and lifecycle hooks are positional, threaded in *ahead* of the middleware pack:

```mojo
app.run_routes_middleware_eh(
    handler,              # H
    JsonErrorHandler(),   # E  — comes before the middleware
    SecurityHeaders(),    # first Ms
    RequestLogger(),      # second Ms
    port=8080,
)

app.run_full(
    handler,              # H
    HtmlErrorHandler(),   # E
    MyLifecycle(),        # L
    SecurityHeaders(),    # Ms...
    port=8080,
)
```

### Growing an app one runner at a time

The methods form a ladder. You climb it as your app needs more.

**Bare.** You own routing:

```mojo
@fieldwise_init
struct Api(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/health":
            return Response.text("ok\n")
        return Response.text("not found\n", 404)

def main() raises:
    App().run(Api(), port=8080)
```

**With routes.** Register patterns, switch to a `RouteHandler`, receive `params` and the matched route `name`:

```mojo
@fieldwise_init
struct Api(RouteHandler, Copyable, Movable):
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        # the route table already matched; branch on the matched route's NAME
        if name == "show_user":
            return Response.text("user " + params.get("id") + "\n")
        return Response.text("not found\n", 404)

def main() raises:
    var app = App()
    app.get("/users/{id}", "show_user")
    app.run_routes(Api(), port=8080)
```

**Full stack.** Routes, a middleware pipeline, a JSON error shape, and startup/shutdown hooks — all in one call:

```mojo
def main() raises:
    var app = App()
    app.get("/users/{id}", "show_user")
    app.run_full(
        Api(),
        JsonErrorHandler(),
        MyLifecycle(),
        SecurityHeaders(),
        RequestLogger(),
        port=8080,
    )
```

Same handler struct throughout (once you're on the routing traits). You're only changing which runner wraps it.

!!! warning "Switching runners can change your handler's signature"
    `run` and `run_middleware` want a **`DispatchHandler`** — `__call__(mut self, req)`. Every other runner wants a **`RouteHandler`** — `__call__(mut self, req, params, name)`. Moving from `run_middleware` to `run_routes_middleware` means adding the `params: Params` and `name: String` parameters to `__call__` (and swapping any `req.path` branching for `if name == "...":`). It's a small edit, but the compiler error ("no matching `__call__`") won't spell it out for you. Know which family you're in.

## The honest rough edge: six runners is a lot

Let's name it, because it's the biggest wart on this API.

Six `run_*` methods is a **combinatorial explosion of optional features.** Routing, middleware, error handling, and lifecycle are four independent switches, and today each *combination* baldr supports is a separately-named method with the features hard-coded into its name and its parameter order. Want routes + lifecycle but *not* a custom error handler? There's no method for that — you take `run_full` and pass a default `JsonErrorHandler()` you didn't ask for. The feature set is a menu, but you can only order the fixed combos.

The shape this *wants* to be is a builder:

```mojo
# NOT the current API — the ergonomic target
App()
    .middleware(SecurityHeaders(), RequestLogger())
    .errors(JsonErrorHandler())
    .lifecycle(MyLifecycle())
    .run(handler, port=8080)
```

One `run`, features composed in any combination, order-independent, each optional. That collapses six methods (and the handful of combinations they *don't* cover) into one path.

Why it isn't built yet: a builder needs the `App` struct to *store* a heterogeneous, optional set of middleware/error/lifecycle values in its fields — and Mojo 1.0 doesn't yet guarantee storable function pointers or trait objects you can stash in an `Optional`. That's the same constraint that made handlers structs in the first place. So for now the features are threaded through compile-time params on each runner instead of stored on the `App`. When Mojo's trait-object story stabilizes, the builder is the plan.

Until then: pick your row in the table, match the handler trait, mind the argument order.

## Recap

- Your app is a **struct** conforming to `DispatchHandler` (`__call__(mut self, req)`) or `RouteHandler` (`+ params, name` — branch on `name` to dispatch).
- It's a struct so it can **own state between requests** — caches, counters, rate limiters, loaders live in fields; `mut self` lets `__call__` update them.
- Compile-time `[H]` / `*Ms` params monomorphize the dispatch — no per-request vtable.
- Pick one of six `run_*` methods; the method decides which handler trait you conform to and what else you pass. Fixed args (`eh`, `lifecycle`) come *before* the `*mws` pack.
- The six-method sprawl is a known rough edge; a builder is the roadmap.

Next: **[Get Started →](../get-started.md)** if you haven't built one yet, or the **[First Steps tutorial →](../tutorial/first-steps.md)** to see the simplest handler end to end.
