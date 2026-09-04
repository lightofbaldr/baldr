# First Steps

The simplest baldr app is a handful of lines. We'll write it, run it, and then take it apart piece by piece.

## The simplest app

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        return Response.text("Hello, baldr\n")

def main() raises:
    var app = App()
    app.run(HelloApp(), port=8080)
```

Build and run it:

```console
$ pixi run build && build/app
[baldr] listening on 0.0.0.0 port 8080

$ curl localhost:8080
Hello, baldr
```

That's a complete web server. Let's walk through it.

## Step 1 — the handler is a struct

```mojo
@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    ...
```

In baldr your app is a **struct** that conforms to the `DispatchHandler` trait. This is the load-bearing idea: the struct *owns its state* between requests. A rate limiter, a template cache, a database handle — they live as fields on this struct, initialized once, reused on every request.

!!! note "Where does `@fieldwise_init` come from? (it's Mojo, not baldr)"
    `@fieldwise_init` is a **built-in Mojo decorator** — part of the language, no import needed. It writes a constructor for you: one argument per field, in declaration order, which is why `HelloApp(String("hi"))` just works. The `Copyable` and `Movable` in the parent list `(DispatchHandler, Copyable, Movable)` are **Mojo trait conformances** (also built in) that synthesize copy/move so baldr can store and hand your handler around. Together they're the standard boilerplate for a plain data-carrying struct — nothing baldr-specific. We'll flag these Mojo-isms as they come up so you're never staring at an unexplained symbol.

## Step 2 — `__call__` handles every request

```mojo
def __call__(mut self, req: Request) raises -> Response:
    return Response.text("Hello, baldr\n")
```

Every incoming request calls this one method. It takes a `Request` and returns a `Response`. `mut self` means the handler can mutate its own state as it serves.

!!! note "Bare strings just work"
    baldr's APIs take the `String` type, and Mojo converts a string literal to `String` for you — so `Response.text("Hello, baldr\n")` needs no wrapper. You may see `String("...")` in older examples; that still works, it's just no longer required. See [Mojo in 5 Minutes](../mojo-primer.md#2-string-and-string-literals).

## Step 3 — the `Response`

`Response` has ready-made builders so you don't hand-assemble HTTP:

```mojo
Response.text("plain text\n")            # text/plain
Response.html("<h1>hi</h1>")             # text/html, auto-escaped helpers available
Response.json(...)                               # application/json
Response.text("nope\n", 404)             # a status code
Response.redirect("/elsewhere")          # 302
```

## Step 4 — `app.run(...)`

```mojo
def main() raises:
    var app = App()
    app.run(HelloApp(), port=8080)
```

`App()` is the server; `.run(handler, port=...)` binds the socket and starts the accept loop. It hands each connection's parsed `Request` to your handler and writes the returned `Response` back on the wire.

## What just happened

```
browser ──HTTP/1.1──▶ baldr socket loop ──parse──▶ Request
                                                     │
                                          HelloApp.__call__(req)
                                                     │
Response ──to_bytes()──▶ HTTP/1.1 on the wire ──▶ browser
```

No interpreter in that path. The whole loop is your one compiled binary.

## Recap

- Your app is a **struct** conforming to `DispatchHandler`; it owns state between requests.
- `__call__(mut self, req) raises -> Response` handles every request.
- `Response.text/html/json/redirect` build the reply.
- `app.run(handler, port=...)` serves it.

Right now our handler answers *everything* the same way. Next we'll route by path and method: **[Routing & Path Params →](routing.md)**.
