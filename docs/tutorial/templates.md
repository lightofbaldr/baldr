# Templates & Responses

So far every response has been a string we built by hand. That's fine for a `<h1>`. It falls apart the moment you have a list to loop over and user input to escape. This page swaps hand-built HTML for a **template engine**: Jinja-shaped, pure Mojo, auto-escaping, and living as a field on your handler.

We'll build a message board — a loop, a conditional, and untrusted input rendered safely.

## Two files

A templated app is two files that talk to each other:

- an **HTML template** with holes in it (`templates/board.html`)
- your **handler**, which fills the holes and renders

The template speaks a small language: `{{ expr }}` to print a value, `{% if %}` / `{% for %}` to branch and loop. Your handler builds a **context** — the data the template reads — and calls `.render()`.

## The template engine is a field

Here's the shape. Read it once; we'll take it apart.

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.template import Value
from baldr.templates import Templates

@fieldwise_init
struct BoardApp(DispatchHandler, Movable):
    var templates: Templates

    def __call__(mut self, req: Request) raises -> Response:
        var ctx = Value.dict()
        ctx.set("title", Value.string("baldr board"))
        var html = self.templates.render("board.html", ctx)
        return Response.html(html)

def main() raises:
    var app = App()
    var templates = Templates("templates")
    app.run(BoardApp(templates=templates^), port=8080)
```

Notice where `Templates` lives: it's a **field on the handler**, constructed once in `main`, reused on every request. That's not a style choice — it's forced by the API, and it's the right shape anyway.

!!! note "Why `Templates` has to be a field"
    `render` is declared `def render(mut self, name, ctx) raises -> String` — it takes **`mut self`** because it caches each parsed template on first use. A method that mutates `self` can only be called on something you own mutably. A fresh `Templates(...)` inside `__call__` would work but would re-read and re-parse the file on *every* request, throwing the cache away each time. Holding it as a field means the file is parsed once and every later request hits the cache. This is the same "handler owns its state" idea from [First Steps](first-steps.md#step-1-the-handler-is-a-struct).

!!! note "`^` is Mojo's transfer operator"
    `BoardApp(templates=templates^)` hands ownership of `templates` into the struct — after the `^`, `main` is done with it. New to `^`, `mut`, and `var`? One table in the [Mojo primer](../mojo-primer.md#3-ownership-mut-var-out) covers all of it.

## Constructing `Templates`

```mojo
Templates("templates")                 # directory, cache parsed templates
Templates("templates", reload=True)    # re-read + re-parse on every render
```

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `directory` | `String` | — | Folder templates are read from. `render("board.html", …)` reads `directory/board.html`. |
| `reload` | `Bool` | `False` | `True` re-reads and re-parses the file on every `.render()`. Handy while editing HTML; leave it off in production. |

!!! tip "`reload=True` is your live-edit loop"
    With `reload=True` you can edit `board.html`, refresh the browser, and see the change — no rebuild. It costs a file read and a parse per request, so flip it back to `False` (the default) before you ship.

## Building the context: a `Value` tree

The template can't read your Mojo structs directly. You hand it a **`Value`** — a small tagged tree of dicts, lists, strings, ints, bools, and floats. Think "the JSON you'd pass to a frontend," built by hand.

There are seven constructors. Each is a `@staticmethod` on `Value`:

| Constructor | Builds | Example |
|---|---|---|
| `Value.dict()` | an empty object (`key → Value`) | the top-level context is almost always this |
| `Value.list_of()` | an empty list | for `{% for x in xs %}` |
| `Value.string(s)` | a string | `Value.string("adam")` |
| `Value.int_(i)` | an integer | `Value.int_(42)` |
| `Value.float_(f)` | a float | `Value.float_(3.5)` |
| `Value.bool_(b)` | a boolean | `Value.bool_(True)` |
| `Value.none()` | the null/empty value | falsy, renders as `""` |

You fill dicts and lists with two mutation methods:

```mojo
dict_value.set("key", some_value^)   # def set(mut self, key: String, var value: Value)
list_value.push(some_value^)                 # def push(mut self, var item: Value)
```

Both **take ownership** of the value you pass, so you transfer it in with `^`. Building the context for our board:

```mojo
var ctx = Value.dict()
ctx.set("title", Value.string("baldr board"))
ctx.set("count", Value.int_(2))

var messages = Value.list_of()

var m1 = Value.dict()
m1.set("who", Value.string("adam"))
m1.set("body", Value.string("first!"))
messages.push(m1^)

var m2 = Value.dict()
m2.set("who", Value.string("bob"))
m2.set("body", Value.string("<script>alert(1)</script>"))
messages.push(m2^)

ctx.set("messages", messages^)
```

That's a dict with three keys: `title`, `count`, and `messages` — a list of two dicts. The template will loop over `messages` and read `.who` / `.body` on each. (Note bob's `body`: hostile input. The engine will neutralize it for us — see [Auto-escaping](#auto-escaping-is-on-by-default) below.)

!!! warning "Building `Value` trees by hand is verbose — today's biggest template rough edge"
    You just wrote nine lines to describe two messages. There's **no struct-to-context binding** yet: baldr can't take your `ChatMsg` struct and turn it into a `Value` for you, so every field is a manual `.set(...)`. It's honest and explicit, but it scales badly. A derive-style `@template_context` (struct → `Value` in one line) is high on the punch-list. For now, a small `to_value(self) -> Value` helper method on your own struct keeps `__call__` tidy.

## The template language

Write `templates/board.html`. It's HTML with four kinds of tag mixed in:

```html
{{ expr }}          print a value (auto-escaped)
{% if %} … {% endif %}    conditional
{% for x in xs %} … {% endfor %}   loop
{# comment #}       stripped from output
```

### `{{ expr }}` — print a value

```html
<title>{{ title }}</title>
<p>{{ count }} messages</p>
<li>{{ m.who }}: {{ m.body }}</li>
```

Dotted access (`m.who`) walks into a dict `Value`. A missing key isn't an error — it evaluates to `none`, which prints as the empty string.

### Filters — transform on the way out

Pipe a value through a filter with `|`:

```html
{{ who|upper }}                     ADAM
{{ body|truncate(80) }}             first 80 chars, then "..."
{{ who|default("anonymous") }}      fallback when who is empty/falsy
{{ tags|length }}                   list/string/dict length
{{ raw_html|safe }}                 opt OUT of auto-escaping (see the warning below)
```

The filters that ship today: `escape` / `e`, `safe`, `upper`, `lower`, `capitalize`, `trim`, `length`, `abs`, `join`, `join(sep)`, `default(arg)`, and `truncate(n)`. Chain them left to right: `{{ who|trim|upper }}`.

!!! note "There's no `title` filter"
    Jinja has one; baldr doesn't (yet). Use `capitalize` for a single leading capital, or `upper` for all-caps. Reaching for a filter that doesn't exist raises `template: unknown filter '…'` at render time.

### `{% if %}` / `{% elif %}` / `{% else %}`

```html
{% if count == 0 %}
  <p class="empty">No messages yet.</p>
{% elif count == 1 %}
  <p>One message.</p>
{% else %}
  <p>{{ count }} messages.</p>
{% endif %}
```

Conditions support comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`) and the logical words `and`, `or`, `not`. Truthiness follows Python: `none`, `0`, `""`, and empty lists/dicts are falsy; everything else is true. So `{% if messages %}` means "if the list is non-empty."

### `{% for x in xs %}`

```html
{% for m in messages %}
  <div class="msg">
    <span class="who">{{ m.who }}</span>
    {{ m.body }}
  </div>
{% endfor %}
```

Inside a loop you also get a `loop` dict, Jinja-style:

| `loop.` field | Value |
|---|---|
| `loop.index` | 1-based position |
| `loop.index0` | 0-based position |
| `loop.first` | `True` on the first iteration |
| `loop.last` | `True` on the last |
| `loop.length` | total count |
| `loop.revindex` / `loop.revindex0` | countdown to the end |

```html
{% for m in messages %}
  <div class="msg {% if loop.first %}top{% endif %}">
    <span class="n">#{{ loop.index }}</span> {{ m.who }}
  </div>
{% endfor %}
```

Iterating a dict walks its **keys** (as strings), same as Python.

### `{% include "name" %}` — compose partials

Pull one template into another. The included file is resolved against the same `Templates` directory:

```html
<!-- board.html -->
<body>
  {% include "header.html" %}
  <main>{{ count }} messages</main>
</body>
```

The partial sees the same context as the page that includes it. Includes are depth-capped (32) so a file that includes itself raises a clear error instead of blowing the stack.

!!! warning "`{% extends %}` and `{% block %}` aren't implemented yet"
    If you know Jinja you'll reach for template *inheritance* — a `base.html` with `{% block content %}` that child pages override. baldr **doesn't have it yet** (it's on the v0.2 roadmap), and `{% block %}` / `{% extends %}` will raise `template: unknown statement`. The composition tool you have today is `{% include %}`: factor shared chrome into `header.html` / `footer.html` and include them. It's bottom-up instead of top-down, but it gets you DRY templates now.

!!! warning "No whitespace control (`{%- … -%}`) yet either"
    Jinja's `-` trim markers that swallow surrounding newlines aren't parsed — a literal `{%- if x -%}` becomes an *unknown statement* (`-` isn't a keyword). Your rendered HTML carries the newlines and indentation exactly as written in the template. Harmless for browsers; occasionally noisy in `curl` output. Also on the v0.2 list.

## Auto-escaping is on by default

This is the reason to use the engine at all. Every `{{ expr }}` is **HTML-escaped automatically**. Remember bob's message — `<script>alert(1)</script>`? Rendered through `{{ m.body }}`, it comes out as inert text:

```html
&lt;script&gt;alert(1)&lt;/script&gt;
```

`&`, `<`, `>`, `"`, and `'` are all converted. You get XSS-safe output for free — you have to work to make it *unsafe*.

!!! warning "`|safe` disables escaping — use it only on HTML you produced"
    `{{ trusted_html|safe }}` prints the value raw, no escaping. That's correct for HTML you built yourself (a rendered Markdown blob you trust). It is a hole the size of your app if you ever pipe user input through it. Rule of thumb: if a human typed it, never `|safe` it.

## Rendering and responding

Back in the handler, `render` turns the template plus context into a `String`, and `Response.html` wraps it with the right `Content-Type`:

```mojo
var html = self.templates.render("board.html", ctx)
return Response.html(html)                     # text/html, 200
return Response.html(html, 404)                # same, with a status code
```

| Call | Signature | Produces |
|---|---|---|
| `templates.render(name, ctx)` | `def render(mut self, name: String, ctx: Value) raises -> String` | the rendered HTML string |
| `Response.html(body)` | `def html(body: String, status: Int = 200) -> Response` | a `text/html` response |

`render` can `raises` — a missing file, an unterminated `{% for %}`, an unknown filter or statement all raise a descriptive `Error`. Because your `__call__` is already `raises`, an uncaught one becomes a 500; catch it if you'd rather serve a friendly error page.

## The whole thing

Handler:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.template import Value
from baldr.templates import Templates

@fieldwise_init
struct BoardApp(DispatchHandler, Movable):
    var templates: Templates

    def __call__(mut self, req: Request) raises -> Response:
        var ctx = Value.dict()
        ctx.set("title", Value.string("baldr board"))

        var messages = Value.list_of()
        var m1 = Value.dict()
        m1.set("who", Value.string("adam"))
        m1.set("body", Value.string("first!"))
        messages.push(m1^)
        var m2 = Value.dict()
        m2.set("who", Value.string("bob"))
        m2.set("body", Value.string("<script>alert(1)</script>"))
        messages.push(m2^)

        ctx.set("count", Value.int_(len(messages.items)))
        ctx.set("messages", messages^)

        var html = self.templates.render("board.html", ctx)
        return Response.html(html)

def main() raises:
    var app = App()
    var templates = Templates("templates")
    app.run(BoardApp(templates=templates^), port=8080)
```

Template — `templates/board.html`:

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>{{ title }}</title></head>
<body>
  <h1>{{ title }}</h1>
  <p><strong>{{ count }}</strong> message{% if count != 1 %}s{% endif %} so far.</p>

  {% if count == 0 %}
    <p class="empty">No messages yet. Be the first.</p>
  {% else %}
    {% for m in messages %}
      <div class="msg">
        <span class="n">#{{ loop.index }}</span>
        <span class="who">{{ m.who|upper }}</span>
        {{ m.body }}
      </div>
    {% endfor %}
  {% endif %}
</body>
</html>
```

Build and hit it:

```console
$ pixi run build && build/app
[baldr] listening on 0.0.0.0 port 8080

$ curl -s localhost:8080
```

bob's `<script>` renders as `&lt;script&gt;…` — safe text, not a live tag. That's the whole point.

## Recap

- **`Templates("dir")`** wraps a template folder; hold it as a **field** on your handler — `render` takes `mut self` and caches parsed templates.
- Build the context as a **`Value` tree**: `Value.dict()` + `.set(key, v^)`, `Value.list_of()` + `.push(v^)`, and the leaf constructors `.string / .int_ / .bool_ / .float_ / .none`.
- The template language is Jinja-shaped: `{{ expr }}` with filters, `{% if/elif/else/endif %}`, `{% for x in xs %}` with a `loop` variable, `{% include %}`, `{# comments #}`.
- `{{ }}` **auto-escapes**; `|safe` opts out (only for HTML you trust).
- Not yet: `{% extends %}` / `{% block %}` inheritance and `{%- -%}` whitespace control — use `{% include %}` for now.
- `Response.html(rendered)` sends it.

The full signature tables live in the **[Templates reference](../reference/templates.md)**. Next, we'll accept and validate real form input: **[Middleware →](middleware.md)**.
