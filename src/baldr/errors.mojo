"""baldr.errors — pluggable error rendering.

Phase 2.7 — error handling. Replaces the inline
`except e: resp = Response.text("500 " + e, 500)` in the accept loops with a
configurable `ErrorHandler` trait. Built-in `JsonErrorHandler` (API apps) and
`HtmlErrorHandler` (browser apps).

The `App` owns its error handler as a typed field (`App[E: ErrorHandler =
DefaultErrorHandler]`): `App()` renders plain text, `App(errors=JsonErrorHandler())`
renders JSON, and the type is fixed at compile time — no trait objects needed.
The deprecated `run_routes_middleware_eh` / `run_full` runners still accept an
error handler as an argument.
"""

from .request import Request
from .response import Response
from .json import JsonValue


trait ErrorHandler(Movable, Deinitable):
    """Render an error response for a (status, message, request) triple."""
    def render_error(self, status: Int, message: String, req: Request) raises -> Response: ...


@fieldwise_init
struct DefaultErrorHandler(ErrorHandler, Defaultable, Copyable, Movable):
    """`App()`'s default: the plain-text errors the bare accept loop always
    produced — `400 Bad Request` for an unparseable request, `500 Internal
    Server Error` when a handler raises."""
    var _unused: Int

    def __init__(out self):
        self._unused = 0

    def render_error(self, status: Int, message: String, req: Request) raises -> Response:
        return Response.text(String(status) + String(" ") + message + String("\n"), status)


@fieldwise_init
struct JsonErrorHandler(ErrorHandler, Defaultable, Copyable, Movable):
    """Default for API apps. Returns `{"error": <label>, "message": ..., "status": <code>}`."""
    var _unused: Int

    def __init__(out self):
        self._unused = 0

    def render_error(self, status: Int, message: String, req: Request) raises -> Response:
        var v = JsonValue.from_object()
        v.set(String("error"), JsonValue.from_string(_status_label(status)))
        v.set(String("message"), JsonValue.from_string(message))
        v.set(String("status"), JsonValue.from_int(status))
        return Response.json(v^, status)


@fieldwise_init
struct HtmlErrorHandler(ErrorHandler, Defaultable, Copyable, Movable):
    """Renders a minimal HTML error page. Apps wanting a templated page can
    conform their own struct to `ErrorHandler` and call `Templates.render`."""
    var _unused: Int

    def __init__(out self):
        self._unused = 0

    def render_error(self, status: Int, message: String, req: Request) raises -> Response:
        var label = _status_label(status)
        var body = String("<!doctype html><html><head><title>") + String(status) + \
            String(" ") + label + String("</title>") + \
            String("<style>body{font-family:system-ui;max-width:560px;margin:4rem auto;padding:1rem;color:#222}h1{color:#c33}</style>") + \
            String("</head><body><h1>") + String(status) + String(" ") + label + String("</h1>") + \
            String("<p>") + _escape_html(message) + String("</p>") + \
            String("<p><a href=\"/\">← home</a></p></body></html>")
        return Response.html(body^, status)


def _status_label(status: Int) -> String:
    if status == 400: return String("bad_request")
    if status == 401: return String("unauthorized")
    if status == 403: return String("forbidden")
    if status == 404: return String("not_found")
    if status == 405: return String("method_not_allowed")
    if status == 409: return String("conflict")
    if status == 422: return String("unprocessable")
    if status == 429: return String("rate_limited")
    if status == 500: return String("internal_error")
    if status == 502: return String("bad_gateway")
    if status == 503: return String("unavailable")
    if status == 504: return String("timeout")
    return String("error")


def _escape_html(s: String) -> String:
    var out = String()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(38):       out += "&amp;"       # &
        elif c == UInt8(60):     out += "&lt;"        # <
        elif c == UInt8(62):     out += "&gt;"        # >
        elif c == UInt8(34):     out += "&quot;"      # "
        elif c == UInt8(39):     out += "&#39;"       # '
        else:                    out += chr(Int(c))
    return out^
