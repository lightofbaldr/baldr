# Capstone: a Notes App

You've met the pieces one at a time — the [handler struct](first-steps.md), [routing](routing.md), templates, JSON, validation. Now we build one small app that uses all of them together and actually runs.

It's a **Notes app**: list your notes, read one, create a new one. Three routes, one handler struct that owns the notes in memory, an auto-escaping template for the list, a JSON `POST` that's validated before it touches state.

```console
$ curl localhost:8080/
$ curl -X POST localhost:8080/notes -d '{"title":"Buy milk","body":"the 2% kind"}'
$ curl localhost:8080/notes/1
```

We'll build it top to bottom. Every symbol below is a real baldr API — if you type it in, it compiles.

## What we're building

| Method | Path | Does |
|---|---|---|
| `GET` | `/` | list all notes (HTML, rendered from a template) |
| `GET` | `/notes/{id}` | show one note |
| `POST` | `/notes` | create a note from a JSON body, validated |

The whole thing is **one struct** that holds a `List[Note]` as a field. That list *is* the database. It lives on the handler between requests — no globals, no external store. That's the load-bearing idea from [First Steps](first-steps.md#step-1-the-handler-is-a-struct), now doing real work.

## The note

Start with the data. A note has an id, a title, and a body:

```mojo
@fieldwise_init
struct Note(Copyable, Movable):
    var id: Int
    var title: String
    var body: String
```

!!! note "`@fieldwise_init` and the `(Copyable, Movable)` list are Mojo, not baldr"
    `@fieldwise_init` writes the constructor (`Note(1, "hi", "...")`) for you; `Copyable, Movable` let baldr store notes in a `List`. Both are built-in Mojo — see the [primer](../mojo-primer.md).

## The handler owns the state

Here's the whole app struct. The `notes` list, a `next_id` counter, and a `Templates` directory all live as fields — initialized once, reused on every request.

```mojo
from baldr.app import App, RouteHandler
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params
from baldr.template import Value
from baldr.templates import Templates
from baldr.json import JsonValue
from baldr.validation import Required, StringLength

@fieldwise_init
struct NotesApp(RouteHandler, Movable):
    var notes: List[Note]
    var next_id: Int
    var templates: Templates
```

Two things changed from the hello-world handler:

- It conforms to **`RouteHandler`**, not `DispatchHandler`. A `RouteHandler`'s `__call__` takes two extra arguments — the `Params` the router extracted from the path (that's how `{id}` reaches your code), and the matched route's `name`, so you dispatch on `name` instead of re-inspecting `req.path`.
- It has real fields. `mut self` (below) is what lets `__call__` push a new note onto `self.notes` and have it still be there next request.

!!! note "Why `Movable` but not `Copyable` here?"
    `App.run_routes` takes ownership of your handler for the life of the server (`var handler: H`), so it only needs to *move* it in once. `Copyable` isn't required and we leave it off — same as the `chat` example. This is a Mojo ownership detail; the [primer](../mojo-primer.md#3-ownership-mut-var-out) covers `var`/`mut`.

## Dispatch: `__call__(mut self, req, params, name)`

One method routes everything. The `App` has already matched the path against the route table before we're called — and tells us which route matched, by name — so here we just branch on `name` and hand off to a small helper for each:

```mojo
    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        if name == "index":
            return Response.html(self.render_index())
        if name == "note_show":
            return self.show(params)
        if name == "note_create":
            return self.create(req)
        return Response.text("404 not found\n", 404)
```

!!! note "Dispatch on `name`, not `req.path`"
    The route table you register in `main()` (below) — `"index"`, `"note_show"`, `"note_create"` — is the single source of truth. The router matches the incoming request against it and hands the matched route's name straight to `__call__`, so the handler never re-derives what the table already knows. (This used to mean re-testing `req.path`/`req.method` and duplicating the route table — fixed in this version by threading `name` through.)

## Listing notes with a template

`render_index` builds a template context and renders it. The context is a `template.Value` tree — a dict at the top, a list of note dicts inside it:

```mojo
    def render_index(mut self) raises -> String:
        var ctx = Value.dict()
        ctx.set("count", Value.int_(len(self.notes)))

        var items = Value.list_of()
        for i in range(len(self.notes)):
            ref n = self.notes[i]
            var v = Value.dict()
            v.set("id", Value.int_(n.id))
            v.set("title", Value.string(n.title))
            v.set("body", Value.string(n.body))
            items.push(v^)
        ctx.set("notes", items^)

        return self.templates.render("index.html", ctx)
```

The `items^` and `v^` are **ownership transfers** — you're handing the value into the list/dict, done with your copy. See the [primer](../mojo-primer.md#3-ownership-mut-var-out) if `^` is new.

The template lives in `templates/index.html`. Note the `{% for %}` loop and the `{% if %}` empty-state — the same tags Jinja gives you:

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Notes</title></head>
<body>
  <h1>{{ count }} notes</h1>

  {% if count == 0 %}
    <p><em>No notes yet. POST one to /notes.</em></p>
  {% else %}
    <ul>
      {% for n in notes %}
        <li><a href="/notes/{{ n.id }}">{{ n.title }}</a></li>
      {% endfor %}
    </ul>
  {% endif %}

  <form method="post" action="/notes">
    <input name="title" placeholder="title" required>
    <button>add</button>
  </form>
</body>
</html>
```

!!! tip "`{{ n.title }}` is auto-escaped"
    baldr's template engine HTML-escapes every `{{ }}` by default. A note titled `<script>` renders as harmless text, not a tag. That's the whole reason to render user content through a template instead of gluing HTML strings together — the safety is automatic. (Opt out per-expression with `|safe`, only when you're sure.)

## Showing one note

`GET /notes/{id}` — the router put `id` into `params`. Pull it out as an `Int`, find the note, render it. We render through a template again so the title and body are auto-escaped:

```mojo
    def show(mut self, params: Params) raises -> Response:
        var id = params.get_int("id")
        for i in range(len(self.notes)):
            ref n = self.notes[i]
            if n.id == id:
                var ctx = Value.dict()
                ctx.set("title", Value.string(n.title))
                ctx.set("body", Value.string(n.body))
                return Response.html(self.templates.render("note.html", ctx))
        return Response.text("404 no such note\n", 404)
```

`params.get_int` parses the `{id}` segment as an `Int`. It returns a default (`0`) if the param is absent, and **raises** if the param is present but not a number — so a request for `/notes/abc` throws. Right now that surfaces as a `500`; ideally it'd be a `404`. We flag it below.

The `templates/note.html` is tiny:

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>{{ title }}</title></head>
<body>
  <h1>{{ title }}</h1>
  <p>{{ body }}</p>
  <p><a href="/">← all notes</a></p>
</body>
</html>
```

## Creating a note: JSON in, validated

This is where it gets interesting. `POST /notes` takes a JSON body. Before we trust it, we **validate** it declaratively: the title must be present and 1–100 characters. If validation fails, we return the framework's structured `422` and never mutate state:

```mojo
    def create(mut self, req: Request) raises -> Response:
        var result = req.validate(
            Required("title"),
            StringLength("title", 1, 100),
        )
        if not result.ok:
            return result.to_response()

        var data = req.json()
        var title = data.get("title").string_val
        var body = data.get("body").string_val

        var note = Note(self.next_id, title, body)
        self.notes.append(note)
        self.next_id += 1

        var out = JsonValue.from_object()
        out.set("id", JsonValue.from_int(note.id))
        out.set("title", JsonValue.from_string(title))
        return Response.json(out^, 201)
```

Walk through what each API does:

| Call | What it does |
|---|---|
| `req.validate(*validators)` | parses the body as JSON, runs the validators, returns a `ValidationResult` |
| `Required("title")` | fails if `title` is absent or `null` |
| `StringLength("title", 1, 100)` | fails if `title`'s string is outside 1–100 bytes (skips if absent — pair it with `Required`) |
| `result.ok` | `True` only if every validator passed |
| `result.to_response()` | renders a `422` with body `{"ok":false,"errors":[...]}` |
| `req.json()` | parses the body into a `JsonValue` tree |
| `data.get(...).string_val` | reads a field's string value out of the parsed object |
| `Response.json(value, 201)` | serializes a `JsonValue` and sets `Content-Type: application/json` |

The validators are just structs conforming to a `Validator` trait, run through a compile-time chain — you can drop in `FieldType("body", "string")` the same way, or write your own. `Required`, `StringLength`, and `FieldType` are the built-in set in `baldr.validation`.

!!! warning "`validate` and `json` both parse the body"
    `req.validate(...)` parses the JSON internally to check it, then throws that parse away; `req.json()` parses it a second time. For a small note body that's fine, but it's wasteful, and there's no way today to get the already-parsed value back out of `validate`. Noted on the punch-list below.

## Wiring it up

`main` registers the routes as data, constructs the handler with its initial (empty) state, and hands it to `run_routes`:

```mojo
def main() raises:
    var app = App()
    app.get("/", "index")
    app.get("/notes/{id}", "note_show")
    app.post("/notes", "note_create")

    var templates = Templates("templates")
    var handler = NotesApp(
        notes=List[Note](),
        next_id=1,
        templates=templates^,
    )
    app.run_routes(handler^, port=8080)
```

The route *names* (`"index"`, `"note_show"`, ...) are exactly what `__call__` branches on above — the route table is the single source of truth for both routing and dispatch. They also still earn their keep on the routing side: registering `/notes/{id}` for `GET` and `/notes` for `POST` is what gives you a real `405 Method Not Allowed` (with an `Allow` header) when someone `DELETE`s a path you only registered for `GET`. That logic lives in the router, not your handler.

!!! note "The template directory is resolved from the working directory"
    `Templates("templates")` looks for `./templates/` relative to **where you run the binary**, not where the binary lives. Run the app from your project root (where `templates/` sits) or the first render raises `template not found`. A binary-relative or embedded-template story is on the roadmap.

## Build and run

Using the `pixi.toml` from [Get Started](../get-started.md#your-project):

```console
$ pixi run build && build/app
[baldr] listening on 0.0.0.0 port 8080 (routes: 3)
```

Now exercise it. Create a couple of notes:

```console
$ curl -X POST localhost:8080/notes -d '{"title":"Buy milk","body":"the 2% kind"}'
{"id":1,"title":"Buy milk"}

$ curl -X POST localhost:8080/notes -d '{"title":"Call Nick","body":""}'
{"id":2,"title":"Call Nick"}
```

List them — the `{% for %}` loop renders each as a link:

```console
$ curl localhost:8080/
<!doctype html>
...
    <ul>
        <li><a href="/notes/1">Buy milk</a></li>
        <li><a href="/notes/2">Call Nick</a></li>
    </ul>
...
```

Read one:

```console
$ curl localhost:8080/notes/1
<!doctype html>
...
  <h1>Buy milk</h1>
  <p>the 2% kind</p>
...
```

Now watch validation reject bad input — an empty title trips `StringLength`:

```console
$ curl -i -X POST localhost:8080/notes -d '{"title":""}'
HTTP/1.1 422 Unprocessable Entity
Content-Type: application/json; charset=utf-8

{"ok":false,"errors":[{"field":"title","code":"min_length","message":"field 'title' must be at least 1 characters"}]}
```

And a missing title trips `Required`:

```console
$ curl -i -X POST localhost:8080/notes -d '{}'
HTTP/1.1 422 Unprocessable Entity
...
{"ok":false,"errors":[{"field":"title","code":"required","message":"field 'title' is required"}]}
```

That's the full app: routing, path params, an auto-escaping template loop, JSON parsing, and declarative validation — one struct that owns its state, compiled to one binary.

!!! warning "State is in-memory and per-process"
    Restart the binary and your notes are gone. And with the prefork worker pool, each worker has its *own* copy of the list — a note created on one worker won't show up on another. That's fine for learning and for read-mostly apps; a real notes service would back `notes` with a store. The point of this capstone is the *shape* — handler-owns-state — not durability.

## What we'd want next

Building this end-to-end, we hit real rough edges. baldr is pre-alpha and we log these honestly — they're the developer-experience punch-list:

- **`validate` re-parses the body.** `req.validate(...)` parses the JSON to check it, discards it, then `req.json()` parses again. We want `validate` to hand back the parsed `JsonValue` so you pay for one parse.
- **No typed JSON accessors.** Pulling a value out is `data.get("title").string_val` — you reach into a raw struct field and silently get an empty string if the type is wrong, instead of `data.get_string("title")` returning an `Optional`. A typed accessor layer would remove a class of quiet bugs.
- **Bad path params raise a 500.** `params.get_int` throws on `/notes/abc` because the `{id}` pattern happily matches non-numeric segments. We want typed route params (`/notes/{id:int}`) that 404 on a mismatch instead of surfacing a 500.
- **Templates resolve from the CWD.** `Templates("templates")` breaks if you run the binary from anywhere but the project root. Embedding templates into the binary (the whole "one static artifact" promise) is the fix we want.

Two items that used to live on this list are fixed: literals now flow into baldr APIs directly (`Response.text("hi")`, no `String(...)` wrap needed), and `RouteHandler.__call__` now receives the matched route's `name` (see "Dispatch" above), so handlers branch on `name` instead of restating the route table as an `if`-chain over `req.path`.

None of these block the app — it builds and serves today. They're exactly the kind of thing this tutorial exists to surface.

---

You've now built a complete baldr app from the ground up. From here:

- **[Guide: The Handler →](../guide/handler.md)** — the state-owning struct pattern in depth.
- **[Reference: Request & Response →](../reference/request-response.md)** — `req.validate`, `req.json`, and every `Response` builder.
- **[Reference: Templates →](../reference/templates.md)** — the full tag and filter set.
