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

    app.run_routes(NotesApp("baldr"), port=8095)
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

## Serving with `run_routes`

A routed app serves with `run_routes`, not `run`:

```mojo
app.run_routes(NotesApp("baldr"), port=8095)
```

```mojo
def run_routes[H: RouteHandler](
    self,
    var handler: H,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises:
```

Per request, `run_routes` resolves the route table **first**, then calls your handler:

- **Path + method match** → your handler is called with the extracted `params` and the matched route's `name`.
- **Path matches but method doesn't** → baldr returns `405 Method Not Allowed` (with an `Allow` header) *without calling your handler*.
- **No path match** → baldr returns `404 Not Found`, also without calling your handler.

So the router handles 404 and 405 at the table level. We'll come back to what that means for the 404 line inside your handler.

!!! note "`[H: RouteHandler]` is a compile-time parameter"
    The `[H: RouteHandler]` in the signature is a [compile-time type parameter](../mojo-primer.md#6-square-brackets-are-compile-time-parameters) — "H is some type conforming to `RouteHandler`, chosen at build time." You never write it; the compiler infers `H = NotesApp` from what you pass. It's why dispatch is monomorphized with no per-request vtable lookup.

## The `RouteHandler` trait

A routed handler is a struct conforming to `RouteHandler`. The trait requires exactly one method:

```mojo
def __call__(mut self, req: Request, params: Params, name: String) raises -> Response: ...
```

Same `__call__` shape as `DispatchHandler` from First Steps, plus two arguments: **`params`**, the path params the router pulled out of the URL, and **`name`**, the matched route's name from the table — the thing you branch on. `mut self` still lets your handler carry state (a counter, a cache) across requests, and `raises` still marks it as able to throw.

!!! note "`def`, `mut self`, and `raises` are Mojo, not baldr"
    If those spellings are new, the one-paragraph tour is in the [primer](../mojo-primer.md#4-def-fn-and-raises). Short version: `def` is the Python-flavored function keyword, `mut self` is a method that may mutate its own struct, and `raises` means "this can throw."

## Reading path params: the `Params` bag

`params` is a `Params` — a small bag of the `{name}` → value bindings the router extracted. Its API:

| Call | Returns | Notes |
|---|---|---|
| `params.get(key, default)` | `String` | the value, or `default` if the key is absent |
| `params.get_int(key, default)` | `Int` (`raises`) | parses the value as an integer |
| `params.has(key)` | `Bool` | is the key present? |
| `params.is_empty()` | `Bool` | were any params extracted? |
| `len(params)` | `Int` | how many params |

Every `key` is a `String`, but bare literals convert automatically, so you write `params.get("id", "?")` directly.

### `get` — a param as text

```mojo
var id = params.get("id", "?")
return Response.text("note #" + id + "\n")
```

`get` never fails. For `GET /notes/42` it returns `"42"`; if `id` somehow isn't bound, you get the default `"?"` instead of a crash.

### `get_int` — a param as a number

URLs are text, so `id` arrives as `"42"`, not `42`. When you want a real integer, `get_int` parses it for you:

```mojo
def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
    if name == "note_show":
        var id = params.get_int("id", 0)   # "42" -> 42
        var next = id + 1
        return Response.text("next note is #" + String(next) + "\n")
    return Response.text("404 not found\n", 404)
```

!!! warning "`get_int` raises on non-numeric input"
    `get_int` returns its `default` if the param is **absent**, but *raises* if the param is **present and not a number** — `GET /notes/banana` throws `param 'id' is not an Int: 'banana'`. That's why the enclosing `__call__` is `raises`. If you'd rather answer `400 Bad Request` than let it propagate to baldr's generic `500`, wrap it in a `try`:

    ```mojo
    var id: Int
    try:
        id = params.get_int("id", 0)
    except:
        return Response.text("400 bad id\n", 400)
    ```

### `has` / `is_empty` / `len`

For routes where a param is genuinely optional, or when one handler serves several patterns, check before you read:

```mojo
if params.has("id"):
    ...                       # a specific note
else:
    ...                       # the whole collection
```

## Dispatch by the matched name

Here's the part worth understanding well *before* you build anything real on baldr's router.

Look again at the two halves of the example. In `main` you declared a clean route table:

```mojo
app.get("/notes/{id}", "note_show")
app.post("/notes", "note_create")
```

Internally, `Router.resolve` builds a `Match` against that table, including the route's `name` (`"note_show"`, `"note_create"`, …). `run_routes` threads that `name` straight through to your handler as its third argument — so inside `__call__` you branch on the same identity the table already assigned, instead of re-deriving it from the path and method:

```mojo
if name == "note_show":
    ...
if name == "note_create":
    ...
```

That keeps the route table as the **single source of truth**: rename a pattern, add a method, reorder routes — none of it touches your `if`-ladder, because the ladder never looks at `req.path`/`req.method` at all. Add a `PUT /notes/{id}` route to the table and forget its `name == "..."` branch, and the request still matches the table (so it isn't a 404), falls through to your final `return`, and you get a clean 404 from *your* code rather than silent mis-routing on a wrong branch.

!!! note "Previously a rough edge — fixed in this version"
    Earlier baldr builds dropped the matched name and left you re-branching on `req.path`/`req.method` by hand — two sources of truth that could drift out of sync. `run_routes` now passes the resolved `name` in, so the table and the handler agree by construction.

A pattern that helps: comment each branch with the verb/pattern it corresponds to, so a reader can line the `if`-ladder up against the route table above `main`:

```mojo
def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
    if name == "index":
        return self.index()                       # GET /
    if name == "note_show":
        return self.show(params)                  # GET /notes/{id}
    if name == "note_create":
        return self.create(req)                   # POST /notes
    if name == "note_delete":
        return self.destroy(params)               # DELETE /notes/{id}
    return Response.text("404 not found\n", 404)
```

## 404 and 405, and who owns them

Because `run_routes` resolves the table before calling you, baldr answers the two common "no route" cases *for you*:

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
- Serve with `app.run_routes(handler, port=...)`; it resolves the table, then calls your handler on a match.
- Your handler conforms to **`RouteHandler`**: `def __call__(mut self, req: Request, params: Params, name: String) raises -> Response`.
- Read params with `params.get(key, default)`, `params.get_int(key, default)` (raises on non-numeric), `params.has(key)`, `params.is_empty()`, `len(params)`.
- baldr answers **404** and **405** (with `Allow`) at the table level, before your handler runs.
- **Dispatch by name:** the router resolves the matched route's `name` and passes it straight to your handler, so `if name == "note_show":` branches match the same table you registered — one source of truth, no drift. Keep the trailing `404` return as a safety net.

Next: build the full **[Notes App →](notes-app.md)** — the same routes, backed by real state on your handler struct.
