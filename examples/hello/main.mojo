"""baldr — hello example.

The README quickstart, end-to-end. Demonstrates:

- Trait-typed dispatcher (`HelloApp` conforms to `DispatchHandler`).
- JSON request body, JSON response.
- Static-mount via runtime registration (data, not handlers).
- Security-headers + request-log middleware woven into the dispatcher.

Build:
    pixi run example-hello
Run:
    build/example-hello
Probe (in another shell):
    curl -s http://127.0.0.1:8090/
    curl -s http://127.0.0.1:8090/api/echo -d '{"msg":"hi"}'
    curl -s http://127.0.0.1:8090/static/probe.txt
"""

from std.time import perf_counter_ns

from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.json import JsonValue, parse as json_parse, dumps as json_dumps
from baldr.middleware.security_headers import apply_security_headers
from baldr.middleware.logger import log_request


@fieldwise_init
struct HelloApp(DispatchHandler, Movable):
    var greeting: String

    def __call__(mut self, req: Request) raises -> Response:
        var t0 = perf_counter_ns()
        var resp: Response

        if req.method == "GET" and req.path == "/":
            resp = Response.html(String(
                "<!doctype html><meta charset=utf-8>"
                "<title>baldr — hello</title>"
                "<h1>") + self.greeting + String("</h1>"
                "<p>You're talking to a pure-Mojo HTTP server.</p>"
                "<ul>"
                "<li><a href='/api/health'>GET /api/health</a></li>"
                "<li>POST /api/echo with a JSON body</li>"
                "<li><a href='/static/probe.txt'>GET /static/probe.txt</a></li>"
                "</ul>"
            ))
        elif req.method == "GET" and req.path == "/api/health":
            var v = json_parse(String("{\"ok\":true,\"service\":\"baldr-hello\"}"))
            resp = Response.json(v, 200)
        elif req.method == "POST" and req.path == "/api/echo":
            try:
                var body = req.json()
                var wrap = JsonValue.from_object()
                wrap.set(String("received"), body^)
                wrap.set(String("method"), JsonValue.from_string(req.method))
                resp = Response.json(wrap^, 200)
            except:
                resp = Response.json(
                    json_parse(String("{\"ok\":false,\"error\":\"bad json\"}")),
                    400,
                )
        else:
            resp = Response.json(
                json_parse(String("{\"ok\":false,\"error\":\"not found\"}")),
                404,
            )

        resp = apply_security_headers(resp^)
        log_request(req, resp, t0)
        return resp^


def main() raises:
    var app = App()
    app.static(String("/static"), String("examples/hello/static"))
    app.run(HelloApp(String("baldr alpha")), port=8090)
