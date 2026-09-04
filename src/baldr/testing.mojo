"""baldr.testing — in-process TestClient (no sockets).

Phase 2.8 — TestClient. Drives a handler end-to-end by constructing a
`Request` and calling `handler.__call__` directly, so tests run fast and
deterministic without binding a port. Doesn't exercise the accept loop /
socket layer (those stay as integration tests via `curl`).

Because `DispatchHandler` and `RouteHandler` are generic, `TestClient` is
parametric over the handler type. Request-builder free functions (`get`,
`post`, `post_json`, `put`, `delete`, `with_header`) keep tests terse.
"""

from std.collections import Dict

from .app import DispatchHandler, RouteHandler
from .request import Request
from .response import Response
from .router import Params, Router, Match, ROUTE_OK, ROUTE_METHOD_NOT_ALLOWED, ROUTE_NOT_FOUND


# ── Request builders ──────────────────────────────────────────────────────
def get(path: String) -> Request:
    var r = Request()
    r.method = String("GET")
    _set_path_query(r, path)
    return r^


def post(path: String, body: String = String()) -> Request:
    var r = Request()
    r.method = String("POST")
    _set_path_query(r, path)
    r.body = body
    return r^


def post_json(path: String, body: String) -> Request:
    var r = post(path, body)
    r.headers[String("Content-Type")] = String("application/json")
    return r^


def put(path: String, body: String = String()) -> Request:
    var r = Request()
    r.method = String("PUT")
    _set_path_query(r, path)
    r.body = body
    return r^


def delete(path: String) -> Request:
    var r = Request()
    r.method = String("DELETE")
    _set_path_query(r, path)
    return r^


def with_header(var req: Request, key: String, value: String) -> Request:
    req.headers[key] = value
    return req^


def _set_path_query(mut r: Request, path: String):
    var q = path.find(String("?"))
    if q < 0:
        r.path = path
    else:
        r.path = String(path[byte=0:q])
        r.query = String(path[byte=q + 1:])


# ── TestClient ────────────────────────────────────────────────────────────
struct TestClient[H: DispatchHandler](Movable):
    """Drive a DispatchHandler in-process. `request(req)` -> Response."""
    var handler: Self.H

    def __init__(out self, var handler: Self.H):
        self.handler = handler^

    def request(mut self, var req: Request) raises -> Response:
        return self.handler(req)


struct RouteTestClient[H: RouteHandler](Movable):
    """Drive a RouteHandler + Router in-process, resolving the route table
    first (so 405/404 mirror the live server) and calling the handler with
    extracted params. Skips static/asset mounts and middleware."""
    var handler: Self.H
    var router: Router

    def __init__(out self, var handler: Self.H, var router: Router):
        self.handler = handler^
        self.router = router^

    def request(mut self, var req: Request) raises -> Response:
        var m = self.router.resolve(req.method, req.path)
        if m.status == ROUTE_OK:
            return self.handler(req, m.params, m.name)
        if m.status == ROUTE_METHOD_NOT_ALLOWED:
            return Response.text(String("405 method not allowed\n"), 405).with_header(String("Allow"), m.allowed)
        return Response.text(String("404 not found\n"), 404)
