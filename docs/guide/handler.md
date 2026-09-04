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
    var app = App()
    app.run(Counter(0, "hello"), port=8080)
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

## One `run`, parts on the App

There is one accept loop, `app.run(handler, port=...)`, and it accepts either
handler trait. What sits between the socket and your handler is decided when
you **construct** the App:

```mojo
struct App[
    M: Middleware = NoMiddleware,        # one stage, or Chain((a, b, c))
    E: ErrorHandler = DefaultErrorHandler,
    L: LifecycleHooks = NoLifecycle,
](Movable)
```

You never write the `[...]`. Pass a part and the compiler infers its type; leave
one out and it is default-constructed:

```mojo
var app = App()                                                  # bare server
var api = App(errors=JsonErrorHandler())                         # JSON error bodies
var site = App(
    middleware=Chain((SecurityHeaders(), RequestLogger())),
    errors=HtmlErrorHandler(),
    lifecycle=MyHooks(),
)
```

Per request: static mounts → asset mount → `middleware.before` → route table
(for a `RouteHandler`) → your handler → `middleware.after`, and any exception is
rendered by the error handler. `lifecycle.on_startup()` runs once before the
bind, `on_shutdown()` once after the loop exits.

### Which trait, then?

`run` is overloaded on the handler's trait, so the question is only about your
handler, never about a runner:

| Your handler conforms to | `run` does | You get |
|---|---|---|
| `DispatchHandler` — `__call__(mut self, req)` | calls it directly; the route table is ignored | route by hand |
| `RouteHandler` — `__call__(mut self, req, params, name)` | resolves `app.get/post/...` first | `params`, the matched `name`, automatic 404 / 405 + `Allow` |

Static mounts (`app.static(...)`) and asset mounts (`app.assets(...)`) work with
both — they are pure data, resolved before middleware and before the handler.

### Growing an app

**Bare.** You own routing:

```mojo
@fieldwise_init
struct Api(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/health":
            return Response.text("ok\n")
        return Response.text("not found\n", 404)

def main() raises:
    var app = App()
    app.run(Api(), port=8080)
```

**With routes.** Register patterns, switch to a `RouteHandler`, receive `params`
and the matched route `name`:

```mojo
@fieldwise_init
struct Api(RouteHandler, Copyable, Movable):
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        if name == "show_user":
            return Response.text("user " + params.get("id") + "\n")
        return Response.text("not found\n", 404)

def main() raises:
    var app = App()
    app.get("/users/{id}", "show_user")
    app.run(Api(), port=8080)
```

**Full stack.** Routes, a middleware pipeline, a JSON error shape, and
startup/shutdown hooks — the parts go on the App, the handler stays the same:

```mojo
def main() raises:
    var app = App(
        middleware=Chain((SecurityHeaders(), RequestLogger())),
        errors=JsonErrorHandler(),
        lifecycle=MyLifecycle(),
    )
    app.get("/users/{id}", "show_user")
    app.run(Api(), port=8080)
```

### Testing without a socket

`app.handle(handler, req)` runs the same pipeline on one in-memory request and
returns the `Response`. Build requests with `baldr.testing.get/post/...`; the
handler is borrowed `mut`, and the parts are public fields, so you can assert on
their state afterwards (`app.middleware.stages[1].befores`).

### Why parameters, not a builder chain

The earlier draft of this page wanted
`App().middleware(...).errors(...).lifecycle(...).run(handler)`. Mojo 1.0 still
cannot store a function or a trait object in a struct field, so a builder that
accumulates *values of unknown type* is not expressible. What it **can** store is
a concrete `M`, `E`, `L` — and a `Chain[*Ms]` holds its stages in a `Tuple`. So
the parts became type parameters with defaults, and because they are fields of
the App, middleware stages are lvalues and may mutate themselves: a stage can
time a request or hold a rate-limit table, which the old variadic runners could
not offer. Per-route *function* binding is the one item that still waits on the
language.

### The deprecated runners

`run_routes`, `run_middleware`, `run_routes_middleware`,
`run_routes_middleware_eh` and `run_full` still compile and behave as in v0.1;
each is `run` with the parts passed as arguments. They ignore the App's own
parts and go away at v0.2 — see the [App reference](../reference/app.md#deprecated-runners)
for the one-line rewrite of each.

## Recap

- Your app is a **struct** conforming to `DispatchHandler` (`__call__(mut self, req)`) or `RouteHandler` (`+ params, name` — branch on `name` to dispatch).
- It's a struct so it can **own state between requests** — caches, counters, rate limiters, loaders live in fields; `mut self` lets `__call__` update them.
- Compile-time `[H]` / `*Ms` params monomorphize the dispatch — no per-request vtable.
- One `run`. The parts — `middleware=`, `errors=`, `lifecycle=` — go on the App at construction; the handler's trait decides whether the route table is resolved.
- Middleware stages are App fields, so they may keep state (`mut self`); `app.handle(handler, req)` runs the pipeline without a socket for tests.

Next: **[Get Started →](../get-started.md)** if you haven't built one yet, or the **[First Steps tutorial →](../tutorial/first-steps.md)** to see the simplest handler end to end.
