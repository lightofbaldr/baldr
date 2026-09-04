# Routing & Path Params

In [First Steps](first-steps.md) our handler answered *everything* the same way. A real app answers `GET /` one way, `GET /notes/42` another, and `POST /notes` a third. That's **routing**: matching an incoming (method, path) to the right code, and pulling the `42` out of the URL as a **path param**.

baldr has a router. It's honest, small, and dispatches by the matched route **name** — the table you register is the single source of truth. Let's build the whole thing.

## The shape of a routed app

Two things change from First Steps:

1. You **declare a route table** on the `App`: `app.get(pattern, name)`, `app.post(...)`, and friends.
2. Your handler conforms to **`RouteHandler`** instead of `DispatchHandler`, and its `__call__` gets two extra arguments: `params` and `name`.

Here's a complete notes API — registration on the bottom, handler on top:

```mojo
from baldr.app import App, RouteHandler
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params


@fieldwise_init
struct NotesApp(RouteHandler, Copyable, Movable):
    var name: String

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        # Dispatch by the matched route NAME — the router already resolved
        # it, so the route table registered in main() is the single source
        # of truth. No re-checking req.path/req.method here.
        if name == "index":
            return Response.html("<h1>" + self.name + " notes</h1>")
        if name == "note_show":
            return Response.text("note #" + params.get("id", "?") + "\n")
        if name == "note_create":
            return Response.text("created\n", 201)
        return Response.text("404 not found\n", 404)


def main() raises:
    var app = App()
    app.get("/", "index")
    app.get("/notes/{id}", "note_show")
    app.post("/notes", "note_create")
    app.delete("/notes/{id}", "note_delete")

    app.run(NotesApp("baldr"), port=8095)
```

Build and poke it:

```console
$ pixi run example-route && build/example-route
[baldr] listening on 0.0.0.0 port 8095 (routes: 4)

$ curl localhost:8095/
<h1>baldr notes</h1>

$ curl localhost:8095/notes/42
note #42

$ curl -X POST localhost:8095/notes
created
```

That's the whole loop. Now let's take it apart.

## Registering routes

You register routes on the `App` before you serve. Each verb has a method:

| Method | Registers | HTTP verb |
|---|---|---|
| `app.get(pattern, name)` | a GET route | `GET` |
| `app.post(pattern, name)` | a POST route | `POST` |
| `app.put(pattern, name)` | a PUT route | `PUT` |
| `app.delete(pattern, name)` | a DELETE route | `DELETE` |
| `app.patch(pattern, name)` | a PATCH route | `PATCH` |

Every one takes two `String` arguments:

- **`pattern`** — the URL shape, e.g. `"/notes/{id}"`. Any `{...}` segment is a named path param.
- **`name`** — a `String` label for the route, e.g. `"note_show"`. It's the route's identity in the table, and it's what you'll branch on in `__call__`.

```mojo
app.get("/notes/{id}", "note_show")
#       └── pattern ──────────┘  └── name ──────────┘
```

!!! note "Bare string literals, no `String(...)` wrap"
    baldr's APIs take `String`, but Mojo converts a string literal to `String` automatically, so you pass `"/notes/{id}"` and `"note_show"` directly — no `String(...)` wrap needed. (Previously a rough edge here — see the [primer](../mojo-primer.md#2-string-and-string-literals) for the underlying Mojo mechanics if you're curious.)

Patterns match segment by segment. `/notes/{id}` matches `/notes/42` (binding `id = "42"`) and `/notes/hello`, but **not** `/notes` (too few segments) or `/notes/42/edit` (too many). A trailing slash on the request path is tolerated.

## Serving a routed app

A routed app serves with the same `run` as everything else — the handler's trait
is what switches the route table on:

```mojo
app.run(NotesApp("baldr"), port=8095)
```

```mojo
def run[H: RouteHandler](
    mut self,
    var handler: H,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises:
```

Per request, `run` resolves the route table **first**, then calls your handler:

- **Path + method match** → your handler is called with the extracted `params` and the matched route's `name`.
- **Path matches but method doesn't** → baldr returns `405 Method Not Allowed` (with an `Allow` header) *without calling your handler*.
- **No path match** → baldr returns `404 Not Found`, also without calling your handler.

So the router handles 404 and 405 at the table level. We'll come back to what that means for the 404 line inside your handler.

## 404 and 405, and who owns them

Because `run` resolves the table before calling you, baldr answers the two common "no route" cases *for you*:

```console
$ curl -i localhost:8095/nope
HTTP/1.1 404 Not Found
...
404 not found

$ curl -i -X DELETE localhost:8095/notes
HTTP/1.1 405 Method Not Allowed
Allow: POST
...
405 method not allowed
```

The `405` even fills in the `Allow` header from every method registered for that path — `resolve` collects them as it scans the table.

So do you still need the `404` line at the bottom of `__call__`? **Yes** — as a safety net. If you register a route in the table but forget its `name == "..."` branch, baldr already decided it's *not* a 404 (a route matched), so control still lands in your handler — and your final `return Response.text("404 not found\n", 404)` is the only thing standing between that request and undefined behavior. Keep it.

## Recap

- Declare routes on the `App`: `app.get/post/put/delete/patch(pattern, name)` — bare string literals, no `String(...)` wrap needed. `{id}` in a pattern is a named param.
- Serve with `app.run(handler, port=...)`; for a `RouteHandler` it resolves the table, then calls your handler on a match.
- Your handler conforms to **`RouteHandler`**: `def __call__(mut self, req: Request, params: Params, name: String) raises -> Response`.
- Read params with `params.get(key, default)`, `params.get_int(key, default)` (raises on non-numeric), `params.has(key)`, `params.is_empty()`, `len(params)`.
- baldr answers **404** and **405** (with `Allow`) at the table level, before your handler runs.
- **Dispatch by name:** the router resolves the matched route's `name` and passes it straight to your handler, so `if name == "note_show":` branches match the same table you registered — one source of truth, no drift. Keep the trailing `404` return as a safety net.

Next: build the full **[Notes App →](notes-app.md)** — the same routes, backed by real state on your handler struct.
