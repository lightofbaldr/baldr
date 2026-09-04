"""Connection-level tests — keep-alive and StreamHandler through `App.serve_connection`.

Everything runs on one end of an AF_UNIX socket pair: the test writes the raw
requests up front, shuts its write side so the server sees EOF afterwards,
calls `serve_connection` on the other end, then reads back every byte the
App wrote. Covers: two requests on one HTTP/1.1 connection, `Connection:
close`, HTTP/1.0 default close, a `RouteHandler` over keep-alive, a
`StreamHandler` sending SSE (and a second stream on the same connection), a
stream handler that raises before `start()`, a static mount on a stream app,
and a request that does not parse.
"""

from std.ffi import c_int
from std.os import makedirs
from std.pathlib import Path

from baldr.app import App, DispatchHandler, RouteHandler, StreamHandler
from baldr.http import socket_pair, socket_close, socket_shutdown_write, write_all, recv_available
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params
from baldr.streaming import ResponseStream


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int

    def __init__(out self):
        self.total = 0
        self.failures = 0

    def check(mut self, label: String, cond: Bool):
        self.total += 1
        if cond:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)

    def summary(self):
        print("---")
        if self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.total - self.failures, "/", self.total, "passed", "—", self.failures, "FAILED")


def _send(fd: c_int, text: String):
    var b = text.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    write_all(fd, out)


def _drain(fd: c_int) -> String:
    """Everything the App wrote, as text (the server has already returned)."""
    var s = String()
    while True:
        var part = recv_available(fd, 65536)
        if len(part) == 0:
            break
        for i in range(len(part)):
            s += chr(Int(part[i]))
    return s^


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var start = 0
    while True:
        var i = hay.find(needle, start)
        if i < 0:
            return n
        n += 1
        start = i + needle.byte_length()


# ── Handlers ──────────────────────────────────────────────────────────────
@fieldwise_init
struct Echo(DispatchHandler, Copyable, Movable):
    var calls: Int

    def __call__(mut self, req: Request) raises -> Response:
        self.calls += 1
        return Response.text(String("echo:") + req.path)


@fieldwise_init
struct Named(RouteHandler, Copyable, Movable):
    var calls: Int

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        self.calls += 1
        return Response.text(String("name=") + name + String(" id=") + params.get(String("id")))


@fieldwise_init
struct Ticker(StreamHandler, Copyable, Movable):
    """Two SSE events per request; raises before start() on /boom."""
    var streams: Int

    def __call__(mut self, req: Request, mut out: ResponseStream) raises:
        if req.path == "/boom":
            raise Error(String("no stream for you"))
        self.streams += 1
        out.start(content_type=String("text/event-stream"))
        out.send_event(String("1"), event=String("tick"), id=String("1"))
        out.send_event(String("2"), event=String("tick"), id=String("2"))
        out.finish()


def main() raises:
    var r = Runner()

    # ── two requests on one HTTP/1.1 connection ──────────────────────────
    var pair = socket_pair()
    var client = pair[0]
    var server = pair[1]
    _send(client, String("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var app = App()
    var echo = Echo(0)
    app.serve_connection(server, echo)
    var wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("keep-alive: two responses on one connection"), _count(wire, String("HTTP/1.1 200 OK")) == 2)
    r.check(String("keep-alive: both bodies served"), wire.find(String("echo:/a")) >= 0 and wire.find(String("echo:/b")) >= 0)
    r.check(String("keep-alive: header says keep-alive"), _count(wire, String("Connection: keep-alive")) == 2)
    r.check(String("keep-alive: handler ran twice"), echo.calls == 2)

    # ── Connection: close ends the loop after one response ───────────────
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var echo2 = Echo(0)
    app.serve_connection(server, echo2)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("close: one response"), _count(wire, String("HTTP/1.1 200 OK")) == 1)
    r.check(String("close: header says close"), wire.find(String("Connection: close")) >= 0 and wire.find(String("Connection: keep-alive")) < 0)
    r.check(String("close: second request not served"), echo2.calls == 1)

    # ── HTTP/1.0 closes by default ───────────────────────────────────────
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /a HTTP/1.0\r\n\r\nGET /b HTTP/1.0\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var echo3 = Echo(0)
    app.serve_connection(server, echo3)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("http/1.0: one response, closed"), _count(wire, String("HTTP/1.1 200 OK")) == 1 and echo3.calls == 1)

    # ── RouteHandler over keep-alive ─────────────────────────────────────
    var rapp = App()
    rapp.get(String("/items/{id}"), String("show"))
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /items/7 HTTP/1.1\r\nHost: x\r\n\r\nGET /items/8 HTTP/1.1\r\nHost: x\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var named = Named(0)
    rapp.serve_connection(server, named)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("routes over keep-alive: both resolved"), wire.find(String("name=show id=7")) >= 0 and wire.find(String("name=show id=8")) >= 0)
    r.check(String("routes over keep-alive: handler ran twice"), named.calls == 2)

    # ── StreamHandler: SSE, then a second stream on the same connection ──
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /events HTTP/1.1\r\nHost: x\r\n\r\nGET /events HTTP/1.1\r\nHost: x\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var ticker = Ticker(0)
    app.serve_connection(server, ticker)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("stream: chunked header"), _count(wire, String("Transfer-Encoding: chunked")) == 2)
    r.check(String("stream: content type"), wire.find(String("Content-Type: text/event-stream")) >= 0)
    r.check(String("stream: events framed"), wire.find(String("event: tick\nid: 1\ndata: 1\n\n")) >= 0 and wire.find(String("id: 2\ndata: 2\n\n")) >= 0)
    r.check(String("stream: terminated"), _count(wire, String("0\r\n\r\n")) == 2)
    r.check(String("stream: second stream on the same connection"), ticker.streams == 2)

    # ── StreamHandler raising before start() → buffered 500 ─────────────
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /boom HTTP/1.1\r\nHost: x\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var ticker2 = Ticker(0)
    app.serve_connection(server, ticker2)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("stream: raise before start -> 500"), wire.find(String("HTTP/1.1 500 Internal Server Error")) >= 0)
    r.check(String("stream: 500 is buffered, not chunked"), wire.find(String("Content-Length:")) >= 0 and wire.find(String("chunked")) < 0)

    # ── StreamHandler app still serves static mounts (buffered) ─────────
    var tmpdir = String("build/keepalive_static")
    makedirs(Path(tmpdir), exist_ok=True)
    var content = String("static-bytes").as_bytes()
    var content_list = List[UInt8](capacity=len(content))
    for i in range(len(content)):
        content_list.append(content[i])
    Path(tmpdir + "/a.txt").write_bytes(content_list)
    var sapp = App()
    sapp.static(String("/static"), tmpdir)
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /static/a.txt HTTP/1.1\r\nHost: x\r\n\r\nGET /events HTTP/1.1\r\nHost: x\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var ticker3 = Ticker(0)
    sapp.serve_connection(server, ticker3)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("stream app: static served buffered"), wire.find(String("static-bytes")) >= 0 and wire.find(String("Content-Length: 12")) >= 0)
    r.check(String("stream app: then a stream on the same connection"), ticker3.streams == 1 and wire.find(String("event: tick")) >= 0)

    # ── a request that does not parse → 400 and close ───────────────────
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("GET /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\nhello"))
    _ = socket_shutdown_write(client)
    var echo4 = Echo(0)
    app.serve_connection(server, echo4)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("bad request: 400"), wire.find(String("HTTP/1.1 400 Bad Request")) >= 0 and echo4.calls == 0)

    r.summary()
