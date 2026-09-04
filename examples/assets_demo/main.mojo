"""Phase 2.6 — asset pipeline demo.

Builds an asset manifest from ./assets at startup, serves the hashed
URLs with immutable cache headers, and renders an HTML page that
references them. Run: pixi run example-assets && build/example-assets  (:8097)
"""
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.assets import build_assets, manifest_to_context
from baldr.template import Value, Template, render


@fieldwise_init
struct PageHandler(DispatchHandler, Copyable, Movable):
    var app_js_url: String
    var style_css_url: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/" and req.method == "GET":
            var ctx = Value.dict()
            ctx.set(String("title"), Value.string(String("assets demo")))
            ctx.set(String("app_js"), Value.string(self.app_js_url))
            ctx.set(String("style_css"), Value.string(self.style_css_url))
            var html = String("<!doctype html><html><head><title>{{ title }}</title>") + \
                String("<link rel=\"stylesheet\" href=\"{{ style_css }}\"></head>") + \
                String("<body><h1>assets demo</h1><script src=\"{{ app_js }}\"></script></body></html>")
            return Response.html(render(Template(html), ctx))
        return Response.text(String("404 not found\n"), 404)


def main() raises:
    var manifest = build_assets(String("examples/assets_demo/assets"),
                                String("examples/assets_demo/static"),
                                String("/static"), True)
    print("[assets] manifest:")
    for i in range(len(manifest.records)):
        print("  ", manifest.records[i].logical_name, "->", manifest.records[i].url)

    var app_js_url = manifest.url_for(String("js/app.js"))
    var style_css_url = manifest.url_for(String("css/style.css"))
    var app = App()
    app.assets(manifest^)
    app.run(PageHandler(app_js_url, style_css_url), port=8097)
