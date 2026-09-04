# Static Files & Assets

A real site serves CSS, JavaScript, images, and fonts. baldr gives you two ways: a plain directory mount for quick work, and a **content-hashed asset pipeline** for production caching. Both are built in — no CDN, no separate static server.

## The quick way: mount a directory

`app.static(url_prefix, dir)` serves files straight off disk:

```mojo
var app = App()
app.static("/static", "./static")
```

Now `GET /static/style.css` returns `./static/style.css` with a sensible content type. That's all you need in development. The catch: the browser can't cache aggressively, because `style.css` might change under the same URL at any time.

## The production way: hashed assets

For deployment you want **immutable URLs** — a file's URL contains a hash of its contents, so when the file changes the URL changes, and browsers can cache each URL *forever*. baldr builds that manifest at startup with `build_assets`:

```mojo
from baldr.assets import build_assets

var manifest = build_assets(
    "./assets",     # source dir you author
    "./static",     # output dir baldr writes hashed copies into
    "/static",      # URL prefix
    True,                   # hash the filenames
)
```

`build_assets` walks `./assets`, copies each file to `./static` under a content-hashed name, and returns an `AssetManifest`. Then you mount it and look up URLs by their **logical** name:

```mojo
var app = App()
app.assets(manifest^)                              # serves the hashed URLs

var css_url = manifest.url_for("css/style.css")   # -> /static/style.a1b2c3.css
```

Hand `css_url` to your template so the page references the fingerprinted URL:

```mojo
var ctx = Value.dict()
ctx.set("style_css", Value.string(manifest.url_for("css/style.css")))
```

!!! note "Runs in-process, at startup"
    `build_assets` is a Mojo function, not an external script — the manifest is built when your server boots. No Node, no webpack, no separate build step to remember. (A watch-mode that rebuilds on change is roadmap.)

## The manifest API

Once you have a manifest, you can inspect and query it:

| Method | Returns |
|---|---|
| `url_for(logical_name)` | the hashed URL for a source file |
| `has(logical_name)` | is this logical name in the manifest? |
| `content_type_for(logical_name)` | the MIME type |
| `records` | the list of `AssetRecord` (`.logical_name`, `.url`) |

```mojo
for i in range(len(manifest.records)):
    print(manifest.records[i].logical_name, "->", manifest.records[i].url)
```

## Full example

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.assets import build_assets
from baldr.template import Value, Template, render

@fieldwise_init
struct PageHandler(DispatchHandler, Copyable, Movable):
    var style_css_url: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/" and req.method == "GET":
            var ctx = Value.dict()
            ctx.set("style_css", Value.string(self.style_css_url))
            var html = "<link rel=\"stylesheet\" href=\"{{ style_css }}\"><h1>hi</h1>"
            return Response.html(render(Template(html), ctx))
        return Response.text("404\n", 404)

def main() raises:
    var manifest = build_assets("./assets", "./static", "/static", True)
    var css = manifest.url_for("css/style.css")
    var app = App()
    app.assets(manifest^)
    app.run(PageHandler(css), port=8097)
```

The served page links `/static/style.<hash>.css`, and baldr returns it with long-lived cache headers — change the file, the hash changes, the browser refetches. No cache-busting query strings, no manual versioning.

!!! tip "Which do I use?"
    Reach for `app.static` while iterating locally; switch to `build_assets` + `app.assets` before you deploy. They're independent — you can even mount a plain dir *and* a hashed manifest at different prefixes.

Next: **[Middleware →](middleware.md)** wraps every request with cross-cutting behavior — logging, rate limits, security headers.
