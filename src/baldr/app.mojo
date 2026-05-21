"""baldr.App — public router + accept loop.

Layers on top of the vendored `http` and `serve` primitives.

In v0.1 the request handler is a **struct that conforms to the
`DispatchHandler` trait** (implements `__call__(self, req) raises ->
Response`). The trait pattern matches Mojo 1.0's first-class function
story: traits give us runtime polymorphism without depending on the
function-pointer-storage support that Mojo 1.0 doesn't yet guarantee.

The dispatcher struct gets to own its state — rate limiter, queues,
templates, etc. — which keeps the bundle's hello / chat / scan
examples honest single-file Mojo binaries.

    @fieldwise_init
    struct HelloApp(DispatchHandler, Copyable, Movable):
        var name: String

        def __call__(self, req: Request) raises -> Response:
            return Response.text(String("hello, ") + self.name)

    def main() raises:
        var app = App()
        app.static(String("/static"), String("./static"))
        app.run(HelloApp(String("world")), port=8080)

Per-route `.get/.post/.put/.delete` registration lands in v0.2 once
Mojo's storable-fn-pointer story stabilizes.

Static mounts ARE registered at runtime since they're pure data.
"""

from std.ffi import c_int
from std.pathlib import Path

from .http import (
    socket_create, socket_reuseaddr, make_sockaddr_in,
    socket_bind, socket_listen, socket_accept, socket_close,
    read_request, write_all,
)
from .request import Request, parse_request
from .response import Response
from .serve import safe_join


trait DispatchHandler(Movable, ImplicitlyDestructible):
    """A request dispatcher. Conform a struct to this trait, hand the
    instance to `App.run()`, and the accept loop will call
    `__call__(req)` on each incoming request. The mutable `self`
    binding lets dispatchers carry per-server state (rate limiters,
    counters, caches) across requests."""
    def __call__(mut self, req: Request) raises -> Response: ...


struct StaticMount(Copyable, Movable):
    var prefix: String
    var dir: String

    def __init__(out self, prefix: String, dir: String):
        self.prefix = prefix
        self.dir = dir


struct App(Copyable, Movable):
    """Router + accept loop. v0.1 uses trait-typed dispatch."""
    var statics: List[StaticMount]

    def __init__(out self):
        self.statics = List[StaticMount]()

    def static(mut self, prefix: String, dir: String):
        """Serve everything under `dir` at URL `prefix/`."""
        self.statics.append(StaticMount(prefix, dir))

    def dispatch_static(self, req: Request) raises -> Response:
        """Resolve a request against the static mount table.
        Raises if no mount matches — callers fall through to their
        own dispatcher when this raises."""
        for i in range(len(self.statics)):
            ref m = self.statics[i]
            if req.path.startswith(m.prefix):
                if req.method != "GET" and req.method != "HEAD":
                    return Response.text(String("405 method not allowed\n"), 405)
                var sub = String(req.path[byte=m.prefix.byte_length():])
                if sub.byte_length() > 0 and sub[byte=0:1] == "/":
                    sub = String(sub[byte=1:])
                var fs = safe_join(m.dir, sub)
                return Response.file(fs)
        raise Error(String("baldr: no static mount matches"))

    def run[H: DispatchHandler](
        self,
        var handler: H,
        host: String = String("0.0.0.0"),
        port: Int = 8080,
    ) raises:
        """Start the accept loop. `handler` is a struct conforming to
        `DispatchHandler`; its `__call__(req)` is invoked per request.
        Static mounts win over the user handler; misses fall through."""
        var sock = socket_create()
        if Int(sock) < 0:
            raise Error(String("baldr: socket() failed"))
        _ = socket_reuseaddr(sock)
        var addr = make_sockaddr_in(port)
        if not socket_bind(sock, addr):
            socket_close(sock)
            raise Error(String("baldr: bind() failed on port ") + String(port))
        if not socket_listen(sock):
            socket_close(sock)
            raise Error(String("baldr: listen() failed"))

        print("[baldr] listening on", host, "port", port)
        while True:
            var client = socket_accept(sock)
            if Int(client) < 0:
                continue
            var raw = read_request(client)
            if len(raw) == 0:
                socket_close(client)
                continue

            var resp: Response
            try:
                var req = parse_request(raw)
                try:
                    resp = self.dispatch_static(req)
                except:
                    resp = handler(req)
            except e:
                resp = Response.text(String("500 ") + String(e) + "\n", 500)
            var resp_bytes = resp.to_bytes()
            write_all(client, resp_bytes)
            socket_close(client)
