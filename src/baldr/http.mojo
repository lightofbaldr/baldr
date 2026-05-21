"""Minimal pure-Mojo HTTP/1.1 server.

Zero external Mojo libraries. Raw POSIX sockets via FFI (`external_call`).
The goal is the smallest credible HTTP server: bind a port, accept one
connection at a time, parse the request line, dispatch to a handler,
write the response.

An OSS contribution to the Mojo ecosystem: general-purpose HTTP
infrastructure. License: Apache-2.0.

Usage:
    pixi run server                    # listens on :8090 by default
    HTTP_PORT=9000 pixi run server

Endpoints (this stub):
    GET /health   -> 200 {"status":"ok","server":"mojo-http","version":"0.1.0"}
    *             -> 404 {"error":"not found"}
"""

from std.ffi import c_int, c_size_t, external_call
from std.memory import UnsafePointer
from std.os.env import getenv


# C constants for AF_INET sockets (POSIX).
comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1
comptime SOL_SOCKET: c_int = 1
comptime SO_REUSEADDR: c_int = 2

comptime DEFAULT_PORT: Int = 8090
comptime LISTEN_BACKLOG: c_int = 16
comptime READ_BUFFER_SIZE: Int = 4096


# ── Socket primitives via FFI ────────────────────────────────────────────
def socket_create() -> c_int:
    """Wrap socket(AF_INET, SOCK_STREAM, 0). Returns fd or -1 on error."""
    return external_call["socket", c_int, c_int, c_int, c_int](
        AF_INET, SOCK_STREAM, c_int(0)
    )


def socket_reuseaddr(fd: c_int) -> Bool:
    """Allow rebinding to the port immediately after close — useful in dev."""
    var one: c_int = 1
    var rc = external_call[
        "setsockopt", c_int,
        c_int, c_int, c_int,
        UnsafePointer[c_int, origin_of(one)], c_int,
    ](fd, SOL_SOCKET, SO_REUSEADDR, UnsafePointer(to=one), c_int(4))
    return Int(rc) == 0


def make_sockaddr_in(port: Int) -> List[UInt8]:
    """Build a 16-byte sockaddr_in bound to 0.0.0.0 on the given port.

    Layout:
        bytes 0-1: sa_family (AF_INET = 2, little-endian)
        bytes 2-3: sin_port (big-endian / network byte order)
        bytes 4-7: sin_addr (0.0.0.0)
        bytes 8-15: padding
    """
    var addr = List[UInt8](capacity=16)
    for _ in range(16):
        addr.append(0)
    addr[0] = UInt8(2)
    addr[2] = UInt8((port >> 8) & 0xFF)
    addr[3] = UInt8(port & 0xFF)
    return addr^


def socket_bind(fd: c_int, mut addr: List[UInt8]) -> Bool:
    var rc = external_call[
        "bind", c_int,
        c_int, UnsafePointer[UInt8, origin_of(addr)], c_int,
    ](fd, addr.unsafe_ptr(), c_int(16))
    return Int(rc) == 0


def socket_listen(fd: c_int) -> Bool:
    var rc = external_call["listen", c_int, c_int, c_int](fd, LISTEN_BACKLOG)
    return Int(rc) == 0


def socket_accept(fd: c_int) -> c_int:
    """Block until a client connects. Returns the client fd or -1."""
    var peer_addr = List[UInt8](capacity=16)
    var peer_len = List[UInt8](capacity=4)
    for _ in range(16):
        peer_addr.append(0)
    peer_len.append(16); peer_len.append(0); peer_len.append(0); peer_len.append(0)
    return external_call[
        "accept", c_int,
        c_int,
        UnsafePointer[UInt8, origin_of(peer_addr)],
        UnsafePointer[UInt8, origin_of(peer_len)],
    ](fd, peer_addr.unsafe_ptr(), peer_len.unsafe_ptr())


def socket_close(fd: c_int) -> None:
    _ = external_call["close", c_int, c_int](fd)


def read_request(fd: c_int) -> List[UInt8]:
    """Read up to READ_BUFFER_SIZE bytes from the client via recv().

    Enough for GET requests with no body and headers under ~4 KB. A real
    implementation loops until it's seen `\r\n\r\n` plus Content-Length bytes.

    Uses `recv` (not `read`) because the Mojo stdlib already binds `write`/
    `read` symbols internally for its own file-descriptor abstraction, and
    duplicate external_call symbol declarations are a hard compile error.
    """
    var buf = List[UInt8](capacity=READ_BUFFER_SIZE)
    for _ in range(READ_BUFFER_SIZE):
        buf.append(0)
    var n = external_call[
        "recv", c_size_t,
        c_int, UnsafePointer[UInt8, origin_of(buf)], c_size_t, c_int,
    ](fd, buf.unsafe_ptr(), c_size_t(READ_BUFFER_SIZE), c_int(0))
    var got = Int(n)
    if got <= 0:
        return List[UInt8]()
    var out = List[UInt8](capacity=got)
    for i in range(got):
        out.append(buf[i])
    return out^


def write_all(fd: c_int, mut data: List[UInt8]) -> None:
    """Loop send() until everything is sent or we hit an error.

    Uses `send` (not `write`) because the Mojo stdlib already binds `write`
    internally — see read_request comment.
    """
    var total: Int = 0
    var n = len(data)
    while total < n:
        var sent = external_call[
            "send", c_size_t,
            c_int, UnsafePointer[UInt8, origin_of(data)], c_size_t, c_int,
        ](fd, data.unsafe_ptr() + total, c_size_t(n - total), c_int(0))
        if Int(sent) <= 0:
            return
        total += Int(sent)


# ── Request parsing ──────────────────────────────────────────────────────
def extract_path(req: List[UInt8]) -> String:
    """Pull the path out of a request line like "GET /health HTTP/1.1\r\n".

    Returns "/" if the line can't be parsed.
    """
    var n = len(req)
    var i: Int = 0
    while i < n and req[i] != UInt8(32):  # space
        i += 1
    if i >= n:
        return "/"
    i += 1  # consume the space
    var start = i
    while i < n and req[i] != UInt8(32) and req[i] != UInt8(13) and req[i] != UInt8(10):
        i += 1
    if i == start:
        return "/"
    var s = String()
    for j in range(start, i):
        s += chr(Int(req[j]))
    return s


# ── HTTP response builder ────────────────────────────────────────────────
def build_response(status_line: String, body: String) -> List[UInt8]:
    """Compose a tiny HTTP/1.1 response. Sets Content-Length and closes."""
    var content_length = body.byte_length()
    var head = String("HTTP/1.1 ") + status_line + "\r\n" \
             + "Content-Type: application/json\r\n" \
             + "Content-Length: " + String(content_length) + "\r\n" \
             + "Connection: close\r\n" \
             + "\r\n"
    var full = head + body
    var bytes = full.as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


# ── Dispatch ─────────────────────────────────────────────────────────────
def handle_request(req: List[UInt8]) -> List[UInt8]:
    var path = extract_path(req)
    if path == "/health":
        return build_response(
            String("200 OK"),
            String('{"status":"ok","server":"mojo-http","version":"0.1.0"}'),
        )
    return build_response(
        String("404 Not Found"),
        String('{"error":"not found"}'),
    )


# ── Demo entry point ─────────────────────────────────────────────────────
# Standalone HTTP-echo demo. Not an entry point in the bundle; Phase 5
# will wrap this as `examples/hello.mojo`.
def _demo() raises:
    var port_env = getenv("HTTP_PORT")
    var port: Int
    if port_env.byte_length() > 0:
        port = atol(port_env)
    else:
        port = DEFAULT_PORT

    print("╔═══════════════════════════════════════════════════╗")
    print("║  mojo-http v0.1.0 — pure-Mojo HTTP/1.1 server     ║")
    print("║  Apache-2.0 · Light of Baldr LLC                  ║")
    print("╚═══════════════════════════════════════════════════╝")
    print("[server] listening on 0.0.0.0:", port)

    var sock = socket_create()
    if Int(sock) < 0:
        print("[fatal] socket() failed")
        return
    _ = socket_reuseaddr(sock)
    var addr = make_sockaddr_in(port)
    if not socket_bind(sock, addr):
        print("[fatal] bind() failed on port", port)
        socket_close(sock)
        return
    if not socket_listen(sock):
        print("[fatal] listen() failed")
        socket_close(sock)
        return

    print("[server] ready — try: curl http://localhost:" + String(port) + "/health")

    while True:
        var client = socket_accept(sock)
        if Int(client) < 0:
            print("[warn] accept() returned -1, continuing")
            continue
        var req = read_request(client)
        if len(req) == 0:
            socket_close(client)
            continue
        var resp = handle_request(req)
        write_all(client, resp)
        socket_close(client)
