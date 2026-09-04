# Testing

You don't need a running server to test a baldr app. `baldr.testing` gives you a **`TestClient`** that calls your handler directly, in-process, with no socket, no port, no accept loop. You build a `Request`, hand it to the client, and get a real `Response` back to assert on. It's fast and deterministic — the whole thing is just a function call.

This is the same idea as FastAPI's `TestClient`, minus the HTTP round-trip: baldr skips the wire entirely and invokes `__call__` for you.

## The shape of a test

A test is a plain Mojo function. Build a request with one of the builder helpers, call `client.request(...)`, check the `Response`:

```mojo
from baldr.request import Request
from baldr.response import Response
from baldr.app import DispatchHandler
from baldr.testing import TestClient, get

@fieldwise_init
struct Greeter(DispatchHandler, Movable):
    var name: String

    def __call__(mut self, req: Request) raises -> Response:
        return Response.text("hello " + self.name)

def test_greeter() raises:
    var client = TestClient[Greeter](Greeter("baldr"))
    var resp = client.request(get("/"))
    if resp.status != 200:
        raise Error("expected 200")
```

No server is started. `client.request(...)` runs `Greeter.__call__` synchronously and returns the `Response` it produced.

!!! note "`TestClient[Greeter]` — the `[...]` is a compile-time parameter"
    `TestClient` is generic over your handler type: `struct TestClient[H: DispatchHandler]`. The type in square brackets is a **compile-time parameter**, resolved when the binary is built, not a runtime argument. Most of the time Mojo infers these for you; here you write it once so the client knows which handler it wraps. See [Mojo in 5 Minutes](../mojo-primer.md).

## Building requests

The builder free functions construct a `Request` for you so you never hand-assemble one. Each returns an owned `Request`:

| Builder | Signature | Produces |
|---|---|---|
| `get` | `get(path: String) -> Request` | a `GET`, splitting `?query` off the path |
| `post` | `post(path: String, body: String = String()) -> Request` | a `POST` with a body |
| `post_json` | `post_json(path: String, body: String) -> Request` | a `POST` with `Content-Type: application/json` |
| `put` | `put(path: String, body: String = String()) -> Request` | a `PUT` with a body |
| `delete` | `delete(path: String) -> Request` | a `DELETE` |
| `with_header` | `with_header(var req: Request, key: String, value: String) -> Request` | the same request with one header added |

`get` and friends split the query string for you, so `get("/search?q=mojo")` gives you `path == "/search"` and `query == "q=mojo"`. `with_header` takes a request and returns it with a header attached, so it chains around a builder:

```mojo
from baldr.testing import get, post_json, with_header

var authed = with_header(get("/me"), "Authorization", "Bearer t0ken")
var created = post_json("/users", "{\"name\":\"ada\"}")
```

!!! note "Bare string literals"
    baldr APIs take the `String` type, but Mojo now converts a string literal to `String` automatically, so you write `get("/")` directly — no `String(...)` wrap (previously a rough edge — fixed in this version). See the [primer](../mojo-primer.md) for how Mojo relates literals to `String`.

## Asserting on the response

The `Response` you get back is the real thing your handler returned. Two fields carry what you'll usually assert on:

- **`resp.status`** — an `Int`. Compare it directly: `resp.status == 200`.
- **`resp.body`** — a `List[UInt8]`, the raw response body bytes.

Status checks are trivial:

```mojo
var resp = client.request(get("/"))
if resp.status != 200:
    raise Error("expected 200, got " + String(resp.status))
```

The body is bytes, so to compare it against an expected `String` you decode it. baldr has no built-in "body as string" accessor, so you loop the bytes yourself:

```mojo
fn body_str(resp: Response) -> String:
    var s = String()
    for i in range(len(resp.body)):
        s += chr(Int(resp.body[i]))
    return s^
```

With that helper the assertions read cleanly:

```mojo
def test_home() raises:
    var client = TestClient[Greeter](Greeter("world"))
    var resp = client.request(get("/"))
    if resp.status != 200:
        raise Error("bad status")
    if body_str(resp) != "hello world":
        raise Error("bad body")
```

!!! warning "Reading the body back as a `String` is clunky"
    There's no `resp.text()` or `resp.body_string()` today — you decode `List[UInt8]` → `String` by hand every time, as in `body_str` above. It works and it's fine for ASCII bodies, but it's boilerplate that belongs in the framework. This is a known rough edge; a body accessor is on the punch-list.

!!! tip "Need the full HTTP wire? Use `to_bytes()`"
    `resp.status` and `resp.body` are the parsed pieces. If you want to assert on the *rendered* HTTP/1.1 response — status line, `Content-Length`, every header, then the body — call `resp.to_bytes()`, which returns the exact `List[UInt8]` baldr would write to the socket. Useful for testing header emission (`Set-Cookie`, redirects, content types) that `resp.body` alone won't show you.

## The transfer operator: `req^`

`request` takes ownership of the request you pass it:

```mojo
def request(mut self, var req: Request) raises -> Response
```

The `var req` means the client **consumes** the request. When you pass a *named variable*, hand off ownership with the transfer operator `^`:

```mojo
var req = get("/dashboard")
req = with_header(req^, "Accept", "text/html")
var resp = client.request(req^)   # req is moved into request(); don't use it after
```

When you pass a builder's result *directly* — `client.request(get("/"))` — there's no `^`, because a freshly-returned value is already an owned temporary with no other owner to transfer from.

!!! note "Why `^`? Mojo tracks ownership"
    Mojo knows exactly one place owns a value at a time. `req^` says "move this out of `req` and into the callee; I'm done with it." Using `req` again after transferring it is a compile error — Mojo catching a use-after-move for you. The [primer](../mojo-primer.md) covers ownership and `^` in two minutes.

## Testing routed apps: `RouteTestClient`

`TestClient` calls your `DispatchHandler` directly — it doesn't know about routes, so it can't produce a `404` or `405` on its own. If your app is a `RouteHandler` driven by a `Router` (the pattern from the [routing tutorial](../tutorial/routing.md)), use **`RouteTestClient`** instead. It resolves the request against the route table *first* — exactly as the live server does — then calls your handler with the extracted path params and the matched route's name. Unmatched paths become `404`; wrong methods become `405` with an `Allow` header, without your handler ever running.

```mojo
from baldr.request import Request
from baldr.response import Response
from baldr.app import RouteHandler
from baldr.router import Router, Params
from baldr.testing import RouteTestClient, get, post

@fieldwise_init
struct Api(RouteHandler, Movable):
    var hits: Int

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        self.hits += 1
        # Dispatch on the matched route NAME, not by re-checking req.path —
        # the route table registered in test_routes() below is the single
        # source of truth.
        if name == "show":
            return Response.text(params.get("id", "?"))
        if name == "create":
            return Response.text(req.body, 201)
        return Response.text("not handled\n", 404)

def test_routes() raises:
    var router = Router()
    router.get("/users/{id}", "show")
    router.post("/users", "create")
    var client = RouteTestClient[Api](Api(0), router^)

    # path param is extracted and passed through
    var r1 = client.request(get("/users/42"))
    # r1.status == 200, body == "42"

    # POST body echoes back with a 201
    var r2 = client.request(post("/users", "ada"))
    # r2.status == 201, body == "ada"

    # wrong method on a known path -> 405, handler never runs
    var r3 = client.request(post("/users/42"))
    # r3.status == 405

    # unknown path -> 404
    var r4 = client.request(get("/nope"))
    # r4.status == 404
```

The constructor takes both your handler and the router, and consumes both — note the `router^` transfer:

```mojo
def __init__(out self, var handler: Self.H, var router: Router)
```

!!! note "What `RouteTestClient` does *not* exercise"
    It resolves routes and calls your handler, but it **skips static-file mounts and middleware**. If you mount an assets directory or wrap handlers in a middleware chain, those layers aren't in the in-process path — cover them with an integration test against a real running binary (a `curl` script). `RouteTestClient` is for your route logic: it mirrors the live server's `404`/`405` behavior, not the whole stack.

## State persists across requests — test it

The load-bearing idea from [First Steps](../tutorial/first-steps.md) is that your handler is a struct that *owns state between requests*. Because `TestClient` holds your handler by value and `request` takes `mut self`, that state survives across calls in a test — so you can drive several requests and assert on the accumulated state:

```mojo
@fieldwise_init
struct Counter(DispatchHandler, Movable):
    var count: Int

    def __call__(mut self, req: Request) raises -> Response:
        self.count += 1
        return Response.text(String(self.count))

def test_counter_accumulates() raises:
    var client = TestClient[Counter](Counter(0))
    _ = client.request(get("/"))
    _ = client.request(get("/"))
    var resp = client.request(get("/"))
    # body is now "3" — the third request saw two prior increments
```

This is exactly why a rate limiter or a cache works in baldr, and it's testable without a socket in sight.

!!! warning "In-process tests don't see cross-worker state"
    baldr's live server preforks worker processes (see [Concurrency](concurrency.md)), so in production your handler state is *per worker*, not global. `TestClient` runs one handler in one process — great for testing a handler's own logic, but it won't reveal state that a real deployment splits across workers. Keep shared, must-be-global state out of handler fields; test that separately.

## Running your tests

A baldr test file is an ordinary Mojo program with a `def main() raises` that calls your test functions. baldr's own suite uses a tiny in-house `Runner` — a struct with a `check(label, cond)` method that tallies pass/fail and prints a summary — rather than a heavyweight test framework. Pre-alpha, and it keeps the suite dependency-free:

```mojo
def main() raises:
    var r = Runner()

    var client = TestClient[Greeter](Greeter("world"))
    var resp = client.request(get("/"))
    r.check("home: status 200", resp.status == 200)
    r.check("home: body", body_str(resp) == "hello world")

    r.summary()
```

Build and run it like any other baldr binary:

```console
$ mojo build tests/test_app.mojo -I src -o build/test_app
$ build/test_app
[ok] home: status 200
[ok] home: body
---
2 / 2 passed
```

baldr ships with **428 assertions across nine suites** — router, JSON, validation, cookies, middleware, templates, concurrency, and the `TestClient` suite itself — all in-process, all fast. When you add a feature, add a suite next to them; the `Runner`-and-`check` pattern above is all there is to it.

!!! warning "There's no assertion library yet"
    baldr has no `assert_equal` / `assert_status` / `pytest`-style runner today. You compare fields with `if`/`raise`, or borrow the `Runner`-and-`check` pattern from `tests/` in the baldr source. It's honest and it works, but a small assertion module (and a `pixi run test` that discovers suites) is squarely on the roadmap.

## Recap

- **`TestClient[H: DispatchHandler](handler)`** drives a dispatcher in-process; `request(req^)` returns a `Response`. No socket.
- **`RouteTestClient[H: RouteHandler](handler, router)`** resolves routes first, so you get real `404`/`405` behavior and extracted path params — but not static mounts or middleware.
- Build requests with `get` / `post` / `post_json` / `put` / `delete` / `with_header`; pass a named request with `req^`.
- Assert on `resp.status` (an `Int`) and `resp.body` (`List[UInt8]`); use `to_bytes()` for the full HTTP wire.
- Handler state persists across `request` calls, so stateful handlers are testable directly.

Next: **[Concurrency →](concurrency.md)** — how baldr serves these handlers in parallel, and what that means for the state you just learned to test.
