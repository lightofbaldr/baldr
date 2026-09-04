"""Phase 2.2 — middleware example.

App(middleware=Chain((SecurityHeaders(), RequestLogger()))) wrapping a handler.
Run: pixi run example-middleware && build/example-middleware   (listens on :8096)
"""
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.middleware.chain import Chain, SecurityHeaders, RequestLogger


@fieldwise_init
struct HelloHandler(DispatchHandler, Copyable, Movable):
    var name: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/" and req.method == "GET":
            return Response.html(String("<h1>") + self.name + "</h1>")
        return Response.text(String("404 not found\n"), 404)


def main() raises:
    var app = App(middleware=Chain((SecurityHeaders(), RequestLogger())))
    app.static(String("/static"), String("./static"))
    app.run(HelloHandler(String("baldr-mw")), port=8096)
