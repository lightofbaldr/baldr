# Router & Params

`baldr.router` is the routing layer: a `Router` holds your routes as plain data and resolves an incoming `(method, path)` to a `Match`. Along the way it extracts path parameters — the `{id}` in `/notes/{id}` — into a `Params` bag your handler reads.

This is a reference page: signature tables plus one focused example per symbol. If you're meeting routing for the first time, walk the tutorial instead — **[Routing & Path Params →](../tutorial/routing.md)** — then come back here for the exact signatures.

```mojo
from baldr.router import Router, Params, RoutePattern, Match, Segment
```

!!! note "Why routes are *data*, not functions"
    Mojo 1.0 can't store a heterogeneous list of `def`-typed handlers in a field. So baldr's `Router` stores each route as `(method, pattern, name)` and resolves to a **name** — a `String` key — plus the extracted `Params`. Your `RouteHandler` then branches on that. It's the "routes are data, handler is a trait" pattern; see [App & Handlers](./app.md) for how `App.run_routes()` wires it up.

---

## `Router`

A table of routes. Register with the verb methods, then resolve.

```mojo
struct Router(Copyable, Movable):
    var entries: List[RouteEntry]
```

| Method | Signature | Notes |
|---|---|---|
| `__init__` | `__init__(out self)` | Empty router. |
| `route` | `route(mut self, method: String, pattern: String, name: String)` | Register any method. `name` is the dispatch key. |
| `get` | `get(mut self, pattern: String, name: String)` | Shorthand for `route("GET", …)`. |
| `post` | `post(mut self, pattern: String, name: String)` | `POST`. |
| `put` | `put(mut self, pattern: String, name: String)` | `PUT`. |
| `delete` | `delete(mut self, pattern: String, name: String)` | `DELETE`. |
| `patch` | `patch(mut self, pattern: String, name: String)` | `PATCH`. |
| `head` | `head(mut self, pattern: String, name: String)` | `HEAD`. |
| `resolve` | `resolve(self, method: String, path: String) -> Match` | Match a live request. See [`Match`](#match). |

Every argument is a `String`, but Mojo converts a bare string literal to `String` automatically, so you just write the literal: `router.get("/", "index")` (previously this needed `String(...)` wraps everywhere — fixed in this version).

!!! note "`mut self` is Mojo, not baldr"
    The verb methods take `mut self` because registering a route mutates the router's `entries`. That's covered in [Mojo in 5 Minutes](../mojo-primer.md).

### Example — build a table and resolve

```mojo
from baldr.router import Router

def demo() raises:
    var r = Router()
    r.get("/", "index")
    r.get("/notes/{id}", "note_show")
    r.post("/notes", "note_create")
    r.delete("/notes/{id}", "note_delete")

    var m = r.resolve("GET", "/notes/42")
    # m.name == "note_show", m.params.get("id") == "42"
```

Routes are matched **in registration order**; the first method-and-path match wins. Register more specific patterns before catch-alls.

!!! note "Same path, several methods"
    `resolve` checks *every* entry whose pattern matches the path, across all methods. So registering both `GET /notes/{id}` and `DELETE /notes/{id}` lets `resolve` tell "wrong method" (405) apart from "no such path" (404). See [`Match`](#match) below.

---

## `Params`

The path-parameter bag handed to your handler. Backed by a `Dict[String, String]`; every value is the raw matched string — convert at read time.

```mojo
struct Params(Copyable, Movable, Sized):
    var data: Dict[String, String]
```

| Method | Signature | Returns / raises |
|---|---|---|
| `__init__` | `__init__(out self)` | Empty bag. |
| `__init__` | `__init__(out self, var data: Dict[String, String])` | Wrap an existing dict. |
| `has` | `has(self, key: String) -> Bool` | Is the key present? |
| `get` | `get(self, key: String, default: String = String()) -> String` | Value, or `default` if absent. |
| `get_int` | `get_int(self, key: String, default: Int = 0) raises -> Int` | Parsed `Int`. `default` if absent; **raises** if present but non-numeric. |
| `is_empty` | `is_empty(self) -> Bool` | True when no params. |
| `__len__` | `__len__(self) -> Int` | Number of params (enables `len(params)`). |

### Example — reading params

```mojo
from baldr.router import Params

def read(params: Params) raises -> String:
    # Present-or-default string:
    var id = params.get("id", "?")

    # Typed read — raises on a non-numeric value like /notes/abc:
    var n = params.get_int("id")

    # Guard before a required read:
    if not params.has("page"):
        return "no page"

    if params.is_empty():
        return "no params at all"

    return "id=" + id
```

!!! warning "`get_int` raises on bad input — catch it"
    `get_int` calls `atol` under the hood. A missing key returns the `default`, but a key that's *present and non-numeric* (`/notes/abc` against `/notes/{id}`) raises `Error("baldr: param 'id' is not an Int: 'abc'")`. Because it can throw, `get_int` is a `raises` function — your handler is already `raises`, so a bare call is fine, but wrap it in `try/except` if you want to return a clean 400 instead of a 500.

!!! note "Values are always `String`"
    baldr does no typed path converters (no `<int:id>` like some frameworks). Every captured segment lands as a `String`; `get_int` is the one built-in coercion. Convert other types yourself from `get`.

---

## `RoutePattern`

A parsed pattern. You rarely build one directly — `Router.route` does it for you — but it's the unit you'd reach for to match a single path against a single pattern.

```mojo
struct RoutePattern(Copyable, Movable):
    var segments: List[Segment]
    var source: String
```

| Method | Signature | Notes |
|---|---|---|
| `__init__` | `__init__(out self, pattern: String)` | Parse `pattern` into segments. |
| `match` | `match(self, path: String) -> Optional[Params]` | `Params` on a match, else `None`. |

### Pattern syntax

| Segment | Meaning |
|---|---|
| `notes` | Literal — must match that path segment exactly. |
| `{id}` | Param — captures the segment into `Params` under the name `id`. |

A pattern is split on `/`; empty segments (leading/trailing slashes) are dropped, so a trailing slash on the request path is tolerated. Matching is **exact on segment count** — `/notes/{id}` matches `/notes/42` but not `/notes` or `/notes/42/comments`.

!!! warning "One-segment params only — no wildcards or regex"
    A `{name}` captures exactly one path segment. There's no `{path:rest}` catch-all, no regex constraints, and no optional segments. Nested paths need one param per level: `/users/{uid}/posts/{pid}`. This is genuinely limited today — a rough edge we're tracking.

### Example — match a single pattern

```mojo
from baldr.router import RoutePattern

def match_one() raises -> String:
    var pat = RoutePattern("/users/{uid}/posts/{pid}")
    var hit = pat.match("/users/7/posts/99")
    if hit:
        var p = hit.value()
        return p.get("uid") + "/" + p.get("pid")  # "7/99"
    return "no match"
```

!!! note "`Optional` is Mojo's maybe-value"
    `match` returns `Optional[Params]`. Test it with `if hit:` and unwrap with `hit.value()` only after the check — unwrapping a `None` traps. `Optional[T]` is standard-library Mojo; the [primer](../mojo-primer.md) has the shape.

---

## `Match`

The result of `Router.resolve`. It folds three outcomes into one struct: matched, wrong-method (405), and not-found (404).

```mojo
struct Match(Copyable, Movable):
    var status: Int       # ROUTE_OK / ROUTE_METHOD_NOT_ALLOWED / ROUTE_NOT_FOUND
    var name: String      # matched route name, on ROUTE_OK
    var params: Params    # extracted params, on ROUTE_OK
    var allowed: String   # comma-joined methods, on ROUTE_METHOD_NOT_ALLOWED
```

| Member | Signature | Notes |
|---|---|---|
| `__init__` | `__init__(out self)` | Defaults to `ROUTE_NOT_FOUND`, empty fields. |
| `not_found` | `@staticmethod not_found() -> Match` | A ready-made 404 result. |
| `status` | `var status: Int` | Compare against the module constants below. |
| `name` | `var name: String` | Dispatch key; meaningful only when `status == ROUTE_OK`. |
| `params` | `var params: Params` | Captured params; empty on a no-param route. |
| `allowed` | `var allowed: String` | On 405, the methods that *do* match the path (e.g. `"GET, DELETE"`) — ready for an HTTP `Allow` header. |

### Status constants

`status` is a plain `Int`, checked against three module-level `comptime` values:

| Constant | Value | Meaning |
|---|---|---|
| `ROUTE_OK` | `0` | Path and method both matched. |
| `ROUTE_METHOD_NOT_ALLOWED` | `1` | Path matched, method didn't → 405; see `allowed`. |
| `ROUTE_NOT_FOUND` | `2` | No pattern matched the path → 404. |

### Example — branch on the outcome

```mojo
from baldr.router import Router, ROUTE_OK, ROUTE_METHOD_NOT_ALLOWED
from baldr.response import Response

def dispatch(mut r: Router, method: String, path: String) raises -> Response:
    var m = r.resolve(method, path)
    if m.status == ROUTE_OK:
        # Route by the matched name; params carry the captures.
        if m.name == "note_show":
            return Response.text("note #" + m.params.get("id") + "\n")
        return Response.text("ok: " + m.name + "\n")
    if m.status == ROUTE_METHOD_NOT_ALLOWED:
        # `with_header` chains and returns a new Response.
        return Response.text("405\n", 405).with_header("Allow", m.allowed)
    return Response.text("404\n", 404)
```

!!! warning "No `is_ok()` helpers — you compare raw `Int`s"
    `Match` has no boolean accessors; you import `ROUTE_OK` / `ROUTE_METHOD_NOT_ALLOWED` / `ROUTE_NOT_FOUND` and compare against `m.status` yourself. In practice you seldom touch `Match` directly: `App.run_routes()` consumes it, threads the matched `name` straight through to your `RouteHandler`, and produces the 405/404 responses for you. (The matched name not reaching the handler — forcing a re-check of `req.path`/`req.method` — was a rough edge; it's fixed now, see below.) See [App & Handlers](./app.md).

---

## `Segment`

The atom of a `RoutePattern`. You'll only see it if you inspect `RoutePattern.segments` directly.

```mojo
struct Segment(Copyable, Movable):
    var kind: Int      # SEG_LITERAL (0) or SEG_PARAM (1)
    var value: String  # literal text, or the param name
```

| Member | Signature | Notes |
|---|---|---|
| `__init__` | `__init__(out self, kind: Int, value: String)` | Build a segment. |
| `kind` | `var kind: Int` | `SEG_LITERAL` or `SEG_PARAM` (module `comptime` constants). |
| `value` | `var value: String` | For a param, `value` is the *name* (`id`), not the matched text. |

For a literal segment `value` is the text to match; for a param segment `value` is the capture name. You almost never construct these by hand — `RoutePattern.__init__` parses them from the pattern string.

---

## In an app

End to end, with `App.run_routes` doing the resolve for you — the router matches, extracts, and hands your `RouteHandler` `(req, params, name)`:

```mojo
from baldr.app import App, RouteHandler
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params

@fieldwise_init
struct NotesApp(RouteHandler, Copyable, Movable):
    var name: String

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        # Dispatch by the matched route NAME — the Router already resolved
        # it, so the route table registered in main() stays the single
        # source of truth (no re-checking req.path/req.method here).
        if name == "note_show":
            return Response.text("note #" + params.get("id", "?") + "\n")
        if name == "note_create":
            return Response.text("created\n", 201)
        return Response.text("404 not found\n", 404)

def main() raises:
    var app = App()
    app.get("/notes/{id}", "note_show")
    app.post("/notes", "note_create")
    app.delete("/notes/{id}", "note_delete")
    app.run_routes(NotesApp("baldr"), port=8095)
```

See **[App & Handlers](./app.md)** for `run_routes` and the middleware/lifecycle variants, and **[Request & Response](./request-response.md)** for the objects your handler works with.
