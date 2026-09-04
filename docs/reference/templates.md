# Templates

A pure-Mojo, Jinja2-flavored HTML template engine. You build a context out of `Value`, hand it to a template, and get back a fully materialized `String` — auto-escaped by default. No Python, no interpreter: the renderer is compiled into your binary like everything else.

Two entry points, one for each altitude:

- **`Templates`** — the filesystem wrapper you'll use in an app. Point it at a directory, render files by name, and `{% include %}` resolves against that same directory. Parses each file once and caches.
- **`Template` + `render`** — the low-level pair, when your source is an in-memory `String` and you don't need includes.

```mojo
from baldr.templates import Templates
from baldr.template  import Value, Template, render, render_with_loader
```

---

## A whole render, end to end

```mojo
from baldr.templates import Templates
from baldr.template  import Value

def render_greeting() raises -> String:
    var tpl = Templates("templates/")     # directory of .html files

    var ctx = Value.dict()
    ctx.set("title", Value.string("Hello & welcome"))

    var users = Value.list_of()
    var u = Value.dict()
    u.set("name", Value.string("adam"))
    u.set("active", Value.bool_(True))
    users.push(u^)
    ctx.set("users", users^)

    return tpl.render("page.html", ctx)
```

With `templates/page.html`:

```html
<h1>{{ title }}</h1>
<ul>
{% for u in users %}
  <li>{{ u.name }}{% if u.active %} (active){% endif %}</li>
{% endfor %}
</ul>
```

`{{ title }}` renders as `Hello &amp; welcome` — the `&` is escaped automatically. That's the whole point: values from your context are HTML-escaped on the way out unless you explicitly opt out with `|safe`.

!!! note "Bare string literals"
    Every template API here takes the `String` type, but Mojo converts a string literal to `String` for you — so you write `ctx.set("title", ...)` and `tpl.render("page.html", ...)` directly, no wrapper. (Older examples wrap literals in `String(...)`; that still works, it's just no longer required — previously a rough edge, fixed in this version.) See [Mojo in 5 Minutes → String](../mojo-primer.md#2-string-and-string-literals).

---

## `Templates`

The filesystem-aware wrapper. Import from `baldr.templates`.

```mojo
struct Templates(Copyable, Movable, TemplateLoader):
    ...
```

| Member | Signature | Notes |
|---|---|---|
| `__init__` | `__init__(out self, directory: String, reload: Bool = False)` | `directory` is a path prefix; a trailing `/` is added if missing. |
| `render` | `render(mut self, name: String, ctx: Value) raises -> String` | Load `directory/name`, parse on first use, render with `ctx`. |
| `load` | `load(self, name: String) raises -> String` | `TemplateLoader` conformance — reads `directory/name` as a string. Raises if the file is missing. |

`render` is `mut self` because the first render of a given name parses the file and appends the result to an internal cache; later renders of the same name reuse the parsed AST. That mutation-between-calls is exactly why a baldr handler holds its `Templates` as a struct field.

!!! note "`mut self` — a Mojo-ism"
    `mut self` means the method may mutate the receiver (here, fill the parse cache). See [Mojo in 5 Minutes → Ownership](../mojo-primer.md#3-ownership-mut-var-out).

### Caching vs. reload

```mojo
var tpl  = Templates("templates/")              # cache on (default)
var dev  = Templates("templates/", reload=True)  # re-read every render
```

- `reload=False` (default): each file is read and parsed **once**, then cached. Fast, but edits to the file on disk are not picked up until the process restarts.
- `reload=True`: re-reads and re-parses on **every** `render` call. Handy while iterating on markup in development; don't ship it.

Because `Templates` conforms to `TemplateLoader`, any `{% include "nav.html" %}` inside a rendered template resolves `nav.html` against the same directory — includes just work.

!!! warning "A missing template raises"
    `render` (via `load`) raises `Error("template not found: ...")` if the file doesn't exist or isn't a regular file. Call it from a `raises` function and decide how to surface the failure — a bare `500` is not built in.

### In a handler

```mojo
from baldr.app       import App, DispatchHandler
from baldr.request   import Request
from baldr.response  import Response
from baldr.templates import Templates
from baldr.template  import Value

@fieldwise_init
struct Site(DispatchHandler, Copyable, Movable):
    var templates: Templates

    def __call__(mut self, req: Request) raises -> Response:
        var ctx = Value.dict()
        ctx.set("path", Value.string(req.path))
        return Response.html(self.templates.render("index.html", ctx))

def main() raises:
    var app = App()
    app.run(Site(Templates("templates/")), port=8080)
```

---

## `Value` — the context type

Everything the template can see is a `Value`. It's a tagged union over six shapes — none, bool, int, float, string, list, dict — and it doubles as the runtime type the expression evaluator works with. You build a dict at the top, fill it, and pass it as `ctx`.

### Constructors

Each is a `@staticmethod` returning a fresh `Value`.

| Constructor | Signature | Builds |
|---|---|---|
| `Value.none()` | `none() -> Value` | the none/null value (renders as `""`, falsy) |
| `Value.bool_(b)` | `bool_(b: Bool) -> Value` | a boolean (note the trailing underscore) |
| `Value.int_(i)` | `int_(i: Int) -> Value` | an integer |
| `Value.float_(f)` | `float_(f: Float64) -> Value` | a float (trailing `.0` is trimmed on output) |
| `Value.string(s)` | `string(s: String) -> Value` | a string |
| `Value.list_of()` | `list_of() -> Value` | an empty list — fill it with `.push(...)` |
| `Value.dict()` | `dict() -> Value` | an empty dict — fill it with `.set(...)` |

!!! note "`bool_`, `int_`, `float_` end in an underscore"
    `bool`, `int`, and `float` collide with builtins, so the constructors carry a trailing `_`. `string`, `list_of`, and `dict` do not. It's an inconsistency worth memorizing.

### Methods

| Method | Signature | Does |
|---|---|---|
| `push` | `push(mut self, var item: Value)` | append to a list value |
| `set` | `set(mut self, key: String, var value: Value)` | set/overwrite a dict key |
| `has` | `has(self, key: String) -> Bool` | is `key` present in the dict? |
| `get` | `get(self, key: String) -> Value` | fetch a dict key (returns `Value.none()` if absent) |
| `truthy` | `truthy(self) -> Bool` | falsy iff none / `False` / `0` / `0.0` / empty string / empty list / empty dict |
| `to_str` | `to_str(self) -> String` | stringify for `{{ }}` output |
| `eq` | `eq(self, other: Value) -> Bool` | structural equality (int↔float compare numerically) |
| `lt` | `lt(self, other: Value) -> Bool` | `<` ordering — strings lexicographically, else numeric |
| `as_float` | `as_float(self) -> Float64` | numeric coercion (bool → 1.0/0.0, else 0.0) |

`push` and `set` take their argument `var` — they take **ownership** of the `Value` you hand in. That's why you see the transfer operator `^` on values you've built and are done with: `users.push(u^)`. See [Mojo in 5 Minutes → Ownership](../mojo-primer.md#3-ownership-mut-var-out).

### Building nested context

```mojo
var ctx = Value.dict()
ctx.set("count", Value.int_(2))

var messages = Value.list_of()
var m = Value.dict()
m.set("who",  Value.string("adam"))
m.set("body", Value.string("first!"))
messages.push(m^)                       # ^ hands ownership to the list
ctx.set("messages", messages^)  # ^ hands ownership to ctx
```

In the template, `messages` is iterable and each item's keys are reachable by dotted access: `{{ m.who }}`, `{{ m.body }}`.

!!! note "`.get` on a missing key never raises"
    `Value.get` returns `Value.none()` for an absent key rather than raising. Dotted access in a template (`a.b.c`) walks `get` at each step, so a wrong path renders as empty string, not an error. Convenient, but it hides typos — `{{ user.naem }}` fails silently.

---

## `Template` and `render` (low-level)

When your source is already an in-memory `String` and you don't need `{% include %}`, skip the filesystem and use `Template` directly.

| Symbol | Signature | Notes |
|---|---|---|
| `Template` | `Template(source: String) raises` | lex + parse the source into an AST once, up front |
| `render` | `render(t: Template, ctx: Value) raises -> String` | render with **no** loader — `{% include %}` raises |
| `render_with_loader` | `render_with_loader[L: TemplateLoader](t: Template, ctx: Value, loader: L) raises -> String` | render with a loader so includes resolve |

```mojo
from baldr.template import Value, Template, render

def hello() raises -> String:
    var t = Template("<h1>{{ title }}</h1>")
    var ctx = Value.dict()
    ctx.set("title", Value.string("hi"))
    return render(t, ctx)
```

`Template(...)` does the parse; `render(...)` walks the AST. If you render the same template many times, build the `Template` once and reuse it — that's exactly what `Templates` does for you behind its cache.

!!! note "`[L: TemplateLoader]` is a compile-time parameter"
    The `[L]` on `render_with_loader` is a type parameter, resolved and monomorphized at build time — you almost never write it explicitly; the compiler infers `L` from the loader you pass. See [Mojo in 5 Minutes → Square brackets](../mojo-primer.md#6-square-brackets-are-compile-time-parameters).

---

## `TemplateLoader` and `NoLoader`

`{% include %}` resolves a partial's name to its source at render time through a **`TemplateLoader`**.

```mojo
trait TemplateLoader(Movable, ImplicitlyDeletable):
    def load(self, name: String) raises -> String: ...
```

Implement `load(name) -> String` and you can back includes with anything — a directory, an embedded map, a database. `Templates` already conforms (its `load` reads from disk), so inside an app you never touch this trait directly.

**`NoLoader`** is the default used by the bare `render(t, ctx)`. It has no partials; calling an include through it raises:

```mojo
struct NoLoader(TemplateLoader, Copyable, Movable):
    def load(self, name: String) raises -> String:
        raise Error("template: {% include %} requires a loader ...")
```

So: if a template uses `{% include %}`, render it through `Templates` or pass a real loader to `render_with_loader`. The plain `render` will raise.

---

## Template grammar

The delimiters, mirroring Jinja2:

| Syntax | Meaning |
|---|---|
| `{{ expr }}` | evaluate `expr`, auto-escape, emit |
| `{% stmt %}` | a statement — `if`, `for`, `include` |
| `{# comment #}` | dropped from output entirely |

### Expressions — `{{ ... }}`

Inside `{{ }}` (and inside `if`/`elif` conditions and `for` iterables) you can write:

- **names & dotted access** — `title`, `user.name`, `a.b.c` (each step is a dict `get`)
- **literals** — numbers (`42`, `3.14`), double- or single-quoted strings, `true`, `false`, `none`
- **comparisons** — `==` `!=` `<` `<=` `>` `>=`
- **logical operators** — `and`, `or`, `not`
- **parentheses** — `(a or b) and c`
- **filters** — `expr | name` or `expr | name(arg)`, chainable

```html
{{ user.name }}
{{ price < 100 and in_stock }}
{{ title | upper }}
{{ bio | default("no bio") | escape }}
```

There is **no arithmetic** (`+ - * /`) in expressions yet — see the gaps below.

### Filters

Piped left-to-right: `{{ value | filter | filter(arg) }}`.

| Filter | Argument | Effect |
|---|---|---|
| `escape` / `e` | — | HTML-escape `& < > " '` |
| `safe` | — | mark as safe — **skip** auto-escaping this value |
| `upper` | — | uppercase |
| `lower` | — | lowercase |
| `capitalize` | — | first codepoint up, rest down |
| `trim` | — | strip leading/trailing ASCII whitespace |
| `length` | — | length of a list, dict, or string (bytes) |
| `abs` | — | absolute value of an int/float |
| `default(x)` | one | `x` when the value is falsy, else the value |
| `join(sep)` | one | join a list into a string with `sep` |
| `truncate(n)` | one int | first `n` codepoints, then `...` if it was longer |

An unknown filter name raises `template: unknown filter '...'`.

### Auto-escaping and `|safe`

Every `{{ }}` value is HTML-escaped on output. That's the safe default — untrusted context can't inject markup.

```html
{{ comment }}          <!-- "<b>hi</b>"  →  &lt;b&gt;hi&lt;/b&gt; -->
{{ comment | safe }}   <!-- "<b>hi</b>"  →  <b>hi</b>  (you vouch for it) -->
```

The renderer is careful about the **last** filter in the chain: ending in `|safe` (you vouch it's safe) *or* `|escape`/`|e` (already escaped) suppresses the extra auto-escape, so `{{ x | escape }}` won't double-escape into `&amp;lt;`. Any other trailing filter leaves the value unsafe and it gets auto-escaped — including `{{ x | safe | upper }}`, where `upper` is last.

### `{% if %}` / `{% elif %}` / `{% else %}` / `{% endif %}`

```html
{% if count == 0 %}
  <p class="empty">nothing yet</p>
{% elif count == 1 %}
  <p>one item</p>
{% else %}
  <p>{{ count }} items</p>
{% endif %}
```

Conditions use the truthiness rules from `Value.truthy` — none, `False`, `0`, `0.0`, `""`, and empty containers are all falsy.

### `{% for x in xs %}` / `{% endfor %}`

Iterates a list (each item bound to `x`) or a dict (each **key**, as a string, bound to `x`):

```html
<ul>
{% for u in users %}
  <li>{{ loop.index }}. {{ u.name }}</li>
{% endfor %}
</ul>
```

Inside the loop body a `loop` dict is available:

| `loop.*` | Value |
|---|---|
| `loop.index` | 1-based position |
| `loop.index0` | 0-based position |
| `loop.first` | `True` on the first item |
| `loop.last` | `True` on the last item |
| `loop.length` | total count |
| `loop.revindex` | count remaining, 1-based |
| `loop.revindex0` | count remaining, 0-based |

!!! note "A non-iterable `for` renders nothing"
    If the iterable expression is a string, number, or `none`, the loop silently produces no output — no error. Matches Jinja's forgiving behavior, but again, it can hide a mistake.

### `{% include "name" %}`

Splices another template in place, resolved through the active loader (the file `directory/name` when you're rendering via `Templates`):

```html
<body>
  {% include "nav.html" %}
  <main>{{ content }}</main>
</body>
```

The included partial sees the **same context** as the point of inclusion — including the current `loop` variable if it's inside a `{% for %}`. The name must be a quoted literal. Recursion is capped at depth 32; a cyclic include raises a clear error rather than overflowing the stack. Remember: includes only resolve through `Templates` or `render_with_loader` — the bare `render` raises.

### Comments

```html
{# this whole tag, and its contents, are removed from the output #}
```

---

## Not implemented yet

The following are **not** supported. This engine is pre-alpha (v0.1), and these are queued but absent today — using them does not degrade gracefully:

!!! warning "`{% extends %}` and `{% block %}` are not implemented"
    Template inheritance does not exist yet. `{% extends "base.html" %}` and `{% block content %}...{% endblock %}` are **not** parsed — they raise `template: unknown statement '...'`. For now, compose pages with `{% include %}` instead: factor shared chrome into partials and include them. Inheritance is on the roadmap for v0.2.

!!! warning "Whitespace-control `{%- -%}` is not implemented"
    The Jinja whitespace-trimming modifiers `{%- ... -%}` and `{{- ... -}}` are not recognized. Because the lexer strips the tag body, a `{%- if x -%}` parses as an unknown statement (`- if x -`) and **raises**. Write your templates without them and manage whitespace by hand for now.

Also absent in v0.1: arithmetic in expressions (`+ - * /`), custom caller-registered filters, and `{% set %}` / `{% with %}` / macros.

---

## See also

- **[First Steps](../tutorial/first-steps.md)** — where `Response.html(...)` comes from.
- **[Request & Response](request-response.md)** — wrap a rendered `String` in `Response.html`.
- **[Mojo in 5 Minutes](../mojo-primer.md)** — `String`, ownership, `mut self`, and compile-time params.
