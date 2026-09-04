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
handler by handing the stages to the App and you're done:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.middleware.chain import Chain, SecurityHeaders, RequestLogger


@fieldwise_init
struct HelloHandler(DispatchHandler, Copyable, Movable):
    var name: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/" and req.method == "GET":
            return Response.html("<h1>" + self.name + "</h1>")
        return Response.text("404 not found\n", 404)


def main() raises:
    var app = App(middleware=Chain((SecurityHeaders(), RequestLogger())))
    app.run(HelloHandler("baldr-mw"), port=8096)
```

```console
$ pixi run example-middleware && build/example-middleware
[baldr] listening on 0.0.0.0 port 8096 (routes: 0)

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

Hand the App one stage, or several composed with `Chain((...))` — a tuple
literal, hence the double parentheses. Then `run` your handler:

```mojo
def main() raises:
    var app = App(middleware=Chain((
        TokenGate("hunter2"),   # runs first
        ServerBanner("baldr"),
        AccessLog("[req]"),
    )))
    app.run(HelloHandler("secure"), port=8080)
```

```console
$ curl -s localhost:8080/                       # no token
401 unauthorized

$ curl -s -H "Authorization: Bearer hunter2" localhost:8080/
<h1>secure</h1>
```

Routed apps compose the same way — the stages are a property of the App, the
handler is a `RouteHandler`, and the route table is resolved after `before`:

```mojo
def main() raises:
    var app = App(middleware=Chain((SecurityHeaders(), AccessLog("[req]"))))
    app.get("/hello/{name}", "hello")
    app.run(MyRouteHandler(), port=8080)
```

!!! note "Mojo-ism: `Chain[*Ms]` is a typed variadic"
    `Chain` is declared `struct Chain[*Ms: Middleware]` and holds its stages in a
    `Tuple[*Ms]`. The `*Ms: Middleware` says "any number of types, each conforming
    to `Middleware`," and the whole pipeline is monomorphized at compile time — no
    per-request vtable, no stored function pointers. You never write the `[ ]`
    params yourself; Mojo infers them from the tuple you pass. Square-bracket
    compile-time params are covered in the [primer](../mojo-primer.md).

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

## Stateful stages

Both hooks take `mut self`. The App owns its middleware as a field, so every
stage is an lvalue and may mutate itself between `before` and `after`, and
across requests. Two built-ins use it:

- `RequestLogger` stamps `perf_counter_ns()` in `before` and logs the elapsed
  milliseconds in `after`;
- `RateLimitMW(cooldown_s, what)` keeps a `RateLimit` table keyed on `req.peer`
  and answers the standard `429` (with `Retry-After`) from `before`.

```mojo
from baldr.middleware.chain import Chain, RateLimitMW, SecurityHeaders

var app = App(middleware=Chain((RateLimitMW(2, "requests"), SecurityHeaders())))
```

A stage that does not need to mutate may still declare `self` on its hooks — the
trait accepts both.

## One runner

`app.run(handler, port=...)` is the only accept loop. The features are decided by
what you construct the App with — `middleware=`, `errors=`, `lifecycle=` — and by
which trait your handler conforms to (`DispatchHandler` routes by hand,
`RouteHandler` gets the route table). The [Handler guide](../guide/handler.md)
walks the combinations. The v0.1 `run_middleware` / `run_routes_middleware`
runners still compile, deprecated, until v0.2.

## Recap

- A middleware stage is a struct conforming to `Middleware`, with `before(mut self, req)
  -> Response` and `after(mut self, req, mut resp)` — both optional, both defaulted.
- `before` returns `MW_PASS` to continue or a real response to short-circuit;
  `after` mutates the response in place.
- Compose with `App(middleware=Chain((a, b, c)))`, then `app.run(handler)` — the
  same for a `DispatchHandler` or a `RouteHandler`.
- Stages are App fields and take `mut self`, so they may keep state; `RequestLogger`
  times requests and `RateLimitMW` rate-limits per peer.
- Order is front-to-back for *both* phases; it's not a reverse-unwind onion.

Next we put routing, templates, JSON, and middleware together into one real
application: **[Capstone: a Notes App →](notes-app.md)**.
