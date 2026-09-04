# Middleware

Some work wraps *every* request: add security headers, log what came in, reject a
caller who forgot their token. You don't want that logic copy-pasted into each
handler. Middleware is where it lives — a small stage that runs **before** your
handler sees the request and **after** it produces the response.

In baldr a middleware stage is a struct that conforms to the `Middleware` trait,
exactly the way a handler is a struct that conforms to `DispatchHandler`. You hand
a pipeline of them to the App and it threads each request through them in order.

## The shortest possible version

baldr ships two ready-made stages, `SecurityHeaders` and `RequestLogger`. Wrap a
handler with `app.run_middleware(handler, ...middleware)` and you're done:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.middleware.chain import SecurityHeaders, RequestLogger


@fieldwise_init
struct HelloHandler(DispatchHandler, Copyable, Movable):
    var name: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/" and req.method == "GET":
            return Response.html("<h1>" + self.name + "</h1>")
        return Response.text("404 not found\n", 404)


def main() raises:
    var app = App()
    app.run_middleware(
        HelloHandler("baldr-mw"),
        SecurityHeaders(),
        RequestLogger(),
        port=8096,
    )
```

```console
$ pixi run example-middleware && build/example-middleware
[baldr] listening on 0.0.0.0 port 8096 (middleware: 2 stages)

$ curl -si localhost:8096/ | head -6
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: default-src 'self'
...
```

The `SecurityHeaders` stage stamped the hardening headers onto the response, and
`RequestLogger` printed a line to the server's stdout:

```console
GET / -> 200
```

That's the whole pattern. Everything below is how to write your *own* stage.

## The `Middleware` trait

Here's the exact trait — two methods, both with defaults, so a stage only overrides
the hook it cares about:

```mojo
trait Middleware(Movable, ImplicitlyDeletable):
    def before(self, req: Request) raises -> Response:
        # default: return a Response with status == MW_PASS to continue
        ...

    def after(self, req: Request, mut resp: Response) raises:
        # default: no-op
        ...
```

- **`before(self, req)`** runs *before* your handler. It returns a `Response`. If
  that response has `status == MW_PASS` (a sentinel, `0`), the chain continues to
  the next stage and eventually your handler. If it returns a *real* response —
  say a `401` or `429` — the pipeline **short-circuits**: your handler never runs,
  and that response goes straight back on the wire.
- **`after(self, req, mut resp)`** runs *after* your handler, and mutates the
  response in place (`mut resp`). No return value. This is where you append headers
  or log the outcome.

!!! note "`MW_PASS`, and why `before` returns a `Response` instead of `Optional`"
    `MW_PASS` is just `comptime MW_PASS = 0`, exported from `baldr.middleware.chain`.
    You'd expect `before` to return `Optional[Response]` — "maybe short-circuit,
    maybe not." It can't: baldr's `Response` holds `List` fields that aren't
    implicitly copyable, so it can't live inside an `Optional`. Returning a plain
    `Response` whose `status` is the `0` sentinel is the copy-free way to say
    "no short-circuit, carry on." A rough edge of today's Mojo, noted honestly.

!!! note "Mojo-ism: `self` is not `mut self`"
    Look closely — `before` and `after` take `self`, **not** `mut self`. A
    middleware stage can't mutate its own fields across requests. Mojo 1.0 dispatches
    the variadic chain over rvalues, and calling a mutating method on an rvalue isn't
    allowed. See [`mut`, `var`, `out`](../mojo-primer.md) in the primer. The practical
    fallout is real and we cover it under [stateful middleware](#the-stateful-limit)
    below.

## Writing your own stage: an `after` hook

A stage that only touches the outgoing response overrides `after` and inherits the
default `before` (which passes). Here's one that stamps a server-name header on
every response:

```mojo
from baldr.request import Request
from baldr.response import Response, Header
from baldr.middleware.chain import Middleware


@fieldwise_init
struct ServerBanner(Middleware, Copyable, Movable):
    var name: String

    def after(self, req: Request, mut resp: Response) raises:
        resp.headers.append(Header("Server", self.name))
```

That's a complete, composable middleware. Because it doesn't override `before`, the
trait's default `before` runs and returns `MW_PASS`, so it never short-circuits — it
just decorates the way out.

!!! note "Mojo-ism: overriding one trait method, inheriting the other"
    The `Middleware` trait gives both methods a real default body, so conforming
    means "override what you need." `ServerBanner` implements only `after`. This is
    the same trait-with-defaults pattern the primer introduces under
    [structs and traits](../mojo-primer.md).

## A request logger you can actually read

The built-in `RequestLogger` logs `method path -> status`. Writing your own is four
lines — and it's worth seeing so you know exactly what's happening:

```mojo
@fieldwise_init
struct AccessLog(Middleware, Copyable, Movable):
    var prefix: String

    def after(self, req: Request, mut resp: Response) raises:
        print(self.prefix, req.method, req.path, "->", String(resp.status))
```

!!! warning "You cannot time a request in a stage"
    The obvious next move — stamp a start time in `before`, read the clock in
    `after`, log the delta — **doesn't work** here. `before` is non-`mut` and
    stateless, so it has nowhere to stash the start time for `after` to read. The
    built-in `RequestLogger` documents this exact limitation in its own source: it
    logs method/path/status and nothing else for this reason. If you need elapsed
    time today, measure it *inside your handler* and add an `X-baldr-elapsed` header
    that a logging stage can pick up. A cleaner story waits on Mojo growing storable
    function pointers / trait objects.

## Short-circuiting: a `before` gate

Override `before` to guard the pipeline. Return `MW_PASS` to let the request through;
return any real response to stop it cold. This gate rejects requests missing a bearer
token:

```mojo
from baldr.middleware.chain import Middleware, MW_PASS


@fieldwise_init
struct TokenGate(Middleware, Copyable, Movable):
    var secret: String

    def before(self, req: Request) raises -> Response:
        var auth = req.header("Authorization")
        if auth == "Bearer " + self.secret:
            var ok = Response()
            ok.status = MW_PASS          # pass: continue the chain
            return ok^
        return Response.text("401 unauthorized\n", 401)
```

Note the two return paths. On success you build a bare `Response()` and set its
`status` to `MW_PASS` — that's the "keep going" signal. On failure you return a real
`401`, and neither your handler nor any later stage runs.

!!! note "Why `Response()` then `ok.status = MW_PASS`?"
    A default `Response()` starts life with `status == 200`, not `0`. So you have to
    set the sentinel explicitly. `req.header(name)` returns an empty `String` when the
    header is absent, so the comparison just falls through to the `401`. The `^` on
    `return ok^` moves the response out — see [ownership](../mojo-primer.md) in the
    primer.

## Wiring it up

Compose a pipeline by listing stages after the handler. For a plain
`DispatchHandler`, use `run_middleware`:

```mojo
def main() raises:
    var app = App()
    app.run_middleware(
        HelloHandler("secure"),
        TokenGate("hunter2"),   # runs first
        ServerBanner("baldr"),
        AccessLog("[req]"),
        port=8080,
    )
```

```console
$ curl -s localhost:8080/                       # no token
401 unauthorized

$ curl -s -H "Authorization: Bearer hunter2" localhost:8080/
<h1>secure</h1>
```

If your app dispatches through a **route table** instead (see
[Routing](routing.md)), swap in `run_routes_middleware` — the same variadic
middleware list, but your handler is a `RouteHandler` that receives the matched
route's extracted path params:

```mojo
def main() raises:
    var app = App()
    app.get("/hello/:name", "hello")
    app.run_routes_middleware(
        MyRouteHandler(),
        SecurityHeaders(),
        AccessLog("[req]"),
        port=8080,
    )
```

!!! note "Mojo-ism: `*mws: *Ms` is a typed variadic"
    Both runners are declared like
    `run_middleware[H: DispatchHandler, *Ms: Middleware](handler, *mws: *Ms)`.
    The `*Ms: Middleware` says "any number of types, each conforming to `Middleware`,"
    and the whole chain is monomorphized at compile time — no per-request vtable, no
    stored function pointers. You never write the `[ ]` params yourself; Mojo infers
    them from the stages you pass. Square-bracket compile-time params are covered in
    the [primer](../mojo-primer.md).

## Order matters (and it's not a strict onion)

Stages run in the order you list them. `TokenGate` above runs its `before` first,
so an unauthorized request is rejected before `ServerBanner` or `AccessLog` do any
work. Put your cheapest rejections first.

!!! warning "The `after` phase runs in the *same* order as `before`, not reversed"
    Classic middleware is an onion: `before` runs A→B→C, `after` runs C→B→A. baldr's
    chain does **not** reverse — both phases iterate the list front-to-back
    (A→B→C, then A→B→C again). For header-stamping and logging this rarely matters,
    but if you're relying on reverse-unwind semantics, you won't get them. Keep your
    stages independent of each other's `after` ordering.

## The stateful limit

You may have noticed there's no built-in rate limiter in the chain. That's
deliberate, and it's the sharpest edge of the current design.

A rate limiter has to remember hit counts *across* requests — it needs `mut self`.
But the variadic chain dispatches over rvalues and can't call a mutating method on a
stage. So **stateful middleware can't live in the chain today.** The workaround is
the pre-middleware pattern: the *handler* owns the stateful struct as a field and
mutates it through its own `mut self` on each call. Your handler is an lvalue; it can
mutate. A middleware stage in the chain is not.

```mojo
@fieldwise_init
struct GuardedApp(DispatchHandler, Copyable, Movable):
    var limiter: RateLimit          # handler owns the state

    def __call__(mut self, req: Request) raises -> Response:
        if not self.limiter.allow(req.path):   # mutates via mut self — allowed
            return Response.text("429 slow down\n", 429)
        return Response.text("ok\n")
```

Stateless concerns (headers, logging, auth gates that read a fixed secret) go in the
chain; stateful concerns (rate limits, counters, per-key caches) stay inside the
handler. A future Mojo with trait objects would collapse the two.

## Which runner do I call?

Here is the genuinely awkward part. baldr has **six** accept-loop entry points, and
which one you call depends on the exact combination of features you want:

| You want… | Call |
| --- | --- |
| a bare handler | `run` |
| a handler + route table | `run_routes` |
| a handler + middleware | `run_middleware` |
| routes + middleware | `run_routes_middleware` |
| routes + middleware + custom error page | `run_routes_middleware_eh` |
| routes + middleware + errors + startup/shutdown hooks | `run_full` |

!!! warning "This is a real rough edge"
    Every feature combination is a differently-named method rather than something you
    compose. Add middleware to a routed app and you rename `run_routes` to
    `run_routes_middleware`; add a custom error handler and it's
    `run_routes_middleware_eh`. It's honest to call this a combinatorial explosion —
    it exists because Mojo 1.0 can't yet store the handler / middleware / error-handler
    as composable trait objects, so each shape is spelled out as its own runner. The
    [Handler guide](../guide/handler.md) has the full decision table and shows how
    `run_full` subsumes the rest.

## Recap

- A middleware stage is a struct conforming to `Middleware`, with `before(self, req)
  -> Response` and `after(self, req, mut resp)` — both optional, both defaulted.
- `before` returns `MW_PASS` to continue or a real response to short-circuit;
  `after` mutates the response in place.
- Compose with `app.run_middleware(handler, ...)` for a `DispatchHandler`, or
  `app.run_routes_middleware(handler, ...)` for a `RouteHandler`.
- Stages are `self`, not `mut self` — stateless only. Stateful concerns (rate
  limiting) live in the handler.
- Order is front-to-back for *both* phases; it's not a reverse-unwind onion.

Next we put routing, templates, JSON, and middleware together into one real
application: **[Capstone: a Notes App →](notes-app.md)**.
