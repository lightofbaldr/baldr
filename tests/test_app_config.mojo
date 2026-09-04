"""ServerConfig wired into the App: `configure()` / `run(handler, config)`, the
413 body cap and 431 header cap on a real connection, the asset mount prefix.

Socket-pair driven like `test_app_keepalive.mojo`: raw requests are written up
front, the write side is shut, `serve_connection` runs on the other end.
"""

from std.ffi import c_int
from std.os import makedirs
from std.pathlib import Path
from std.sys import argv
from std.time import perf_counter_ns

from baldr.app import App, DispatchHandler
from baldr.assets import build_assets
from baldr.config import ServerConfig
from baldr.http import socket_pair, socket_close, socket_shutdown_write, write_all, recv_available
from baldr.request import Request
from baldr.response import Response
from baldr.testing import get


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
    var s = String()
    while True:
        var part = recv_available(fd, 65536)
        if len(part) == 0:
            break
        for i in range(len(part)):
            s += chr(Int(part[i]))
    return s^


def _body(resp: Response) -> String:
    var s = String()
    for i in range(len(resp.body)):
        s += chr(Int(resp.body[i]))
    return s^


@fieldwise_init
struct Echo(DispatchHandler, Copyable, Movable):
    var calls: Int

    def __call__(mut self, req: Request) raises -> Response:
        self.calls += 1
        return Response.text(String("echo:") + req.path)


def main() raises:
    var r = Runner()
    var stamp = String(perf_counter_ns())

    # ── configure(): the cap, debug, and a static mount when the dir exists ─
    var static_dir = String("build/config_static_") + stamp
    makedirs(Path(static_dir), exist_ok=True)
    var cfg = ServerConfig(
        host=String("127.0.0.1"), port=0, debug=True, workers=1,
        max_body_bytes=16, static_dir=static_dir, template_dir=String("templates"),
    )
    var app = App()
    app.configure(cfg)
    r.check(String("configure: body cap applied"), app.max_body_bytes == 16)
    r.check(String("configure: debug applied"), app.debug)
    r.check(String("configure: static_dir mounted at /static"), len(app.statics) == 1 and app.statics[0].dir == static_dir)
    var missing = ServerConfig(
        host=String("127.0.0.1"), port=0, debug=False, workers=1,
        max_body_bytes=1024, static_dir=String("build/does_not_exist_") + stamp, template_dir=String("templates"),
    )
    var app2 = App()
    app2.configure(missing)
    r.check(String("configure: absent static_dir is not mounted"), len(app2.statics) == 0)

    # ── 413: declared body over the cap, before any body byte is read ──────
    var pair = socket_pair()
    var client = pair[0]
    var server = pair[1]
    _send(client, String("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 999\r\n\r\n"))
    _ = socket_shutdown_write(client)
    var echo = Echo(0)
    app.serve_connection(server, echo)
    var wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("413: status line"), wire.find(String("HTTP/1.1 413 Payload Too Large")) >= 0)
    r.check(String("413: handler not called"), echo.calls == 0)
    r.check(String("413: connection closed"), wire.find(String("Connection: close")) >= 0)

    # ── a body within the cap still works ──────────────────────────────────
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    _send(client, String("POST /ok HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
    _ = socket_shutdown_write(client)
    var echo2 = Echo(0)
    app.serve_connection(server, echo2)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("cap: body within the cap served"), wire.find(String("echo:/ok")) >= 0 and echo2.calls == 1)

    # ── 431: a header block over MAX_HEADER_BYTES ──────────────────────────
    pair = socket_pair()
    client = pair[0]
    server = pair[1]
    var pad = String("X-Pad: ")
    for _ in range(1000):
        pad += "aaaaaaaaaa"
    pad += "\r\n"
    var huge = String("GET /h HTTP/1.1\r\nHost: x\r\n")
    for _ in range(8):
        huge += pad
    _send(client, huge)                    # ~80 KB of headers, never terminated
    _ = socket_shutdown_write(client)
    var echo3 = Echo(0)
    app.serve_connection(server, echo3)
    wire = _drain(client)
    socket_close(client)
    socket_close(server)
    r.check(String("431: status line"), wire.find(String("HTTP/1.1 431 Request Header Fields Too Large")) >= 0)
    r.check(String("431: handler not called"), echo3.calls == 0)

    # ── asset mount prefix is honoured ─────────────────────────────────────
    var root = String("build/config_assets_") + stamp
    var outdir = root + String("_out")
    makedirs(Path(root), exist_ok=True)
    makedirs(Path(outdir), exist_ok=True)
    Path(root + String("/app.js")).write_text(String("var a = 1;\n"))
    var manifest = build_assets(root, outdir, String("/static"), False)
    var url = manifest.url_for(String("app.js"))          # "/static/app.<hash>.js"
    var outside = App()
    outside.assets(manifest.copy(), String("/assets"))    # mounted elsewhere than the manifest's URLs
    var echo4 = Echo(0)
    var resp_outside = outside.handle(echo4, get(url))
    r.check(String("assets: URL outside the mount prefix falls through to the handler"), _body(resp_outside) == String("echo:") + url and echo4.calls == 1)
    var inside = App()
    inside.assets(manifest^, String("/static"))
    var echo5 = Echo(0)
    var resp_inside = inside.handle(echo5, get(url))
    r.check(String("assets: URL under the mount prefix is served"), resp_inside.status == 200 and _body(resp_inside).find(String("var a")) >= 0 and echo5.calls == 0)

    # ── run(handler, config) overloads exist (never executed: it would bind) ─
    if len(argv()) > 5:
        var never = Echo(0)
        app.run(never^, cfg)

    r.summary()
