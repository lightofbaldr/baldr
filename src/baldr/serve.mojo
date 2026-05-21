"""mojo-serve — a tiny pure-Mojo static-file HTTP server.

Designed to feel like the npm `serve` package: `serve .` and you get
your current directory hosted on a port. Single binary, no runtime
dependencies, no config file.

A Flask/FastAPI-inspired routing core (Request/Response/route table) lives
inside but isn't surfaced as a public Mojo API yet — that's the v0.2 story.
v0.1 ships the static-file CLI, which is the killer demo.

Build:
    pixi run build         → build/serve  (~95 KB on linux-aarch64)

Use:
    ./build/serve                       # serves . on :8000
    ./build/serve --port 3000 .         # explicit port + path
    ./build/serve --port 3000 ./public  # serve a subdirectory
    ./build/serve --no-listing .        # disable directory listings

Flags:
    --port N        Port to bind (default 8000).
    --host H        Address to bind (default 0.0.0.0).
    --listing       Auto-generate HTML directory listings (default ON).
    --no-listing    Refuse to enumerate directories without an index.html.
    --help, -h      Print usage and exit.

Returns HTTP/1.1; one connection at a time; no keep-alive; no range
requests yet. That's enough for "host this directory and let me curl /
file:// it" which is what the v0.1 user actually wants.
"""

from std.ffi import c_int, c_size_t, external_call
from std.memory import UnsafePointer
from std.pathlib import Path
from std.sys import argv


# ── Socket constants (AF_INET / SOCK_STREAM on Linux) ────────────────────
comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1
comptime SOL_SOCKET: c_int = 1
comptime SO_REUSEADDR: c_int = 2

comptime DEFAULT_PORT: Int = 8000
comptime LISTEN_BACKLOG: c_int = 16
comptime READ_BUFFER_SIZE: Int = 8192


# ── Low-level socket primitives via FFI ──────────────────────────────────
def socket_create() -> c_int:
    return external_call["socket", c_int, c_int, c_int, c_int](
        AF_INET, SOCK_STREAM, c_int(0)
    )


def socket_reuseaddr(fd: c_int) -> Bool:
    var one: c_int = 1
    var rc = external_call[
        "setsockopt", c_int,
        c_int, c_int, c_int,
        UnsafePointer[c_int, origin_of(one)], c_int,
    ](fd, SOL_SOCKET, SO_REUSEADDR, UnsafePointer(to=one), c_int(4))
    return Int(rc) == 0


def make_sockaddr_in(port: Int) -> List[UInt8]:
    """Build a 16-byte sockaddr_in bound to 0.0.0.0 on the given port."""
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


# ── HTTP request parsing ─────────────────────────────────────────────────
struct Request(Copyable, Movable):
    """Just the parts of a request our static handler actually uses."""
    var method: String
    var path: String

    def __init__(out self):
        self.method = String("GET")
        self.path = String("/")


def parse_request(req: List[UInt8]) -> Request:
    """Parse the request line: `METHOD SP PATH SP VERSION CRLF`.

    Returns a Request with sensible defaults if parsing fails — the handler
    will see method="GET" path="/" and respond 404, which is fine.
    """
    var r = Request()
    var n = len(req)
    if n == 0:
        return r^

    # Method = bytes up to first space.
    var i: Int = 0
    while i < n and req[i] != UInt8(32):
        i += 1
    var method = String()
    for j in range(i):
        method += chr(Int(req[j]))
    r.method = method^

    if i >= n:
        return r^
    i += 1  # consume space

    # Path = bytes up to next space or CR/LF.
    var path_start = i
    while i < n and req[i] != UInt8(32) and req[i] != UInt8(13) and req[i] != UInt8(10):
        i += 1
    var path = String()
    for j in range(path_start, i):
        path += chr(Int(req[j]))
    if path.byte_length() == 0:
        path = String("/")
    r.path = path^

    return r^


# ── URL-decode + path sanitization ───────────────────────────────────────
def url_decode(s: String) -> String:
    """Decode %XX percent-escapes. Quietly leaves a stray %X uninterpreted."""
    var out = String()
    var b = s.as_bytes()
    var n = len(b)
    var i: Int = 0
    while i < n:
        var c = b[i]
        if c == UInt8(37) and i + 2 < n:  # '%'
            var hi = _hex_digit(b[i + 1])
            var lo = _hex_digit(b[i + 2])
            if hi >= 0 and lo >= 0:
                out += chr(Int(UInt8(hi * 16 + lo)))
                i += 3
                continue
        if c == UInt8(43):  # '+'
            out += " "
            i += 1
            continue
        out += chr(Int(c))
        i += 1
    return out^


def _hex_digit(c: UInt8) -> Int:
    var v = Int(c)
    if v >= 48 and v <= 57:
        return v - 48
    if v >= 65 and v <= 70:
        return v - 55
    if v >= 97 and v <= 102:
        return v - 87
    return -1


def safe_join(root: String, request_path: String) -> String:
    """Resolve `request_path` against `root`, refusing path-traversal escapes.

    - Strips a leading '/' on the request path so it's relative.
    - Drops the query string (anything after '?').
    - Splits on '/', collapses '..' but never lets the depth go negative —
      so a request like `/../../../etc/passwd` resolves to root, not the
      filesystem root.
    - Returns the joined absolute-ish path; the caller then stats it.
    """
    # Strip query string.
    var q_idx = request_path.find("?")
    var rp: String
    if q_idx >= 0:
        rp = String(request_path[byte=:q_idx])
    else:
        rp = request_path

    # URL-decode the path component only (we don't care about query for static).
    rp = url_decode(rp)

    # Strip leading '/'.
    if rp.startswith("/"):
        rp = String(rp[byte=1:])

    var parts = rp.split("/")
    var safe = List[String]()
    for var p in parts:
        if p.byte_length() == 0 or p == ".":
            continue
        if p == "..":
            if len(safe) > 0:
                _ = safe.pop()
            continue
        safe.append(String(p))

    # Recombine.
    var out = String(root)
    if not out.endswith("/"):
        out += "/"
    for k in range(len(safe)):
        out += safe[k]
        if k < len(safe) - 1:
            out += "/"
    return out^


# ── MIME types ───────────────────────────────────────────────────────────
def mime_for(path: String) -> String:
    """Map common extensions → MIME types. Defaults to application/octet-stream."""
    var lower = path.lower()
    # Walk extensions longest-first to disambiguate (e.g. .tar.gz vs .gz).
    if lower.endswith(".html") or lower.endswith(".htm"):
        return String("text/html; charset=utf-8")
    if lower.endswith(".css"):
        return String("text/css; charset=utf-8")
    if lower.endswith(".js") or lower.endswith(".mjs"):
        return String("application/javascript; charset=utf-8")
    if lower.endswith(".json"):
        return String("application/json; charset=utf-8")
    if lower.endswith(".txt") or lower.endswith(".md"):
        return String("text/plain; charset=utf-8")
    if lower.endswith(".xml"):
        return String("application/xml; charset=utf-8")
    if lower.endswith(".svg"):
        return String("image/svg+xml")
    if lower.endswith(".png"):
        return String("image/png")
    if lower.endswith(".jpg") or lower.endswith(".jpeg"):
        return String("image/jpeg")
    if lower.endswith(".gif"):
        return String("image/gif")
    if lower.endswith(".webp"):
        return String("image/webp")
    if lower.endswith(".ico"):
        return String("image/vnd.microsoft.icon")
    if lower.endswith(".pdf"):
        return String("application/pdf")
    if lower.endswith(".wasm"):
        return String("application/wasm")
    if lower.endswith(".mp4"):
        return String("video/mp4")
    if lower.endswith(".woff2"):
        return String("font/woff2")
    if lower.endswith(".woff"):
        return String("font/woff")
    if lower.endswith(".ttf"):
        return String("font/ttf")
    return String("application/octet-stream")


# ── Response builder ─────────────────────────────────────────────────────
def build_response(
    status_line: String,
    content_type: String,
    mut body: List[UInt8],
) -> List[UInt8]:
    """Compose an HTTP/1.1 response with proper Content-Length and close."""
    var head = String("HTTP/1.1 ") + status_line + "\r\n" \
             + "Content-Type: " + content_type + "\r\n" \
             + "Content-Length: " + String(len(body)) + "\r\n" \
             + "Server: mojo-serve/0.1.0\r\n" \
             + "Connection: close\r\n" \
             + "\r\n"
    var head_bytes = head.as_bytes()
    var out = List[UInt8](capacity=len(head_bytes) + len(body))
    for i in range(len(head_bytes)):
        out.append(head_bytes[i])
    for i in range(len(body)):
        out.append(body[i])
    return out^


def build_response_text(status_line: String, content_type: String, body: String) -> List[UInt8]:
    var body_bytes = body.as_bytes()
    var body_list = List[UInt8](capacity=len(body_bytes))
    for i in range(len(body_bytes)):
        body_list.append(body_bytes[i])
    return build_response(status_line, content_type, body_list)


# ── Directory listing ────────────────────────────────────────────────────
def directory_listing_html(rel_path: String, entries: List[Path]) -> String:
    """Render a simple HTML directory index. Keeps the markup minimal so
    the page is readable in `lynx`/`w3m` as well as a regular browser."""
    var display: String
    if rel_path.byte_length() == 0 or rel_path == "/":
        display = String("/")
    else:
        display = rel_path

    var html = String("<!doctype html>\n<html><head><meta charset=\"utf-8\">")
    html += "<title>Index of " + display + "</title>"
    html += "<style>body{font-family:ui-monospace,SFMono-Regular,monospace;"
    html += "max-width:60rem;margin:2rem auto;padding:0 1rem;color:#222}"
    html += "h1{font-size:1.1rem;font-weight:600;margin-bottom:1rem}"
    html += "a{text-decoration:none;color:#0366d6}"
    html += "a:hover{text-decoration:underline}"
    html += "ul{list-style:none;padding:0}li{padding:0.15rem 0}"
    html += "</style></head><body>"
    html += "<h1>Index of " + display + "</h1>"
    html += "<ul>"
    # Parent link, except when we're at the root of the served tree.
    if rel_path.byte_length() > 0 and rel_path != "/":
        html += "<li><a href=\"../\">../</a></li>"

    # Folders first, files second, both alphabetical.
    var dirs = List[String]()
    var files = List[String]()
    for var entry in entries:
        var name = String(entry.path)
        # Path objects render as full paths — pluck just the basename.
        var slash = name.rfind("/")
        if slash >= 0:
            name = String(name[byte=slash + 1:])
        if name.byte_length() == 0:
            continue
        if entry.is_dir():
            dirs.append(name + "/")
        else:
            files.append(String(name))

    # Simple insertion sort — fine for typical directory sizes.
    _sort_strings(dirs)
    _sort_strings(files)

    for k in range(len(dirs)):
        html += "<li><a href=\"" + dirs[k] + "\">" + dirs[k] + "</a></li>"
    for k in range(len(files)):
        html += "<li><a href=\"" + files[k] + "\">" + files[k] + "</a></li>"

    html += "</ul></body></html>\n"
    return html^


def _sort_strings(mut xs: List[String]):
    var n = len(xs)
    for i in range(1, n):
        var j = i
        while j > 0 and xs[j] < xs[j - 1]:
            var tmp = String(xs[j])
            xs[j] = String(xs[j - 1])
            xs[j - 1] = tmp^
            j -= 1


# ── Static-file handler ──────────────────────────────────────────────────
def handle_static(
    root: String,
    req: Request,
    allow_listing: Bool,
) -> List[UInt8]:
    if req.method != "GET" and req.method != "HEAD":
        return build_response_text(
            String("405 Method Not Allowed"),
            String("text/plain; charset=utf-8"),
            String("405 method not allowed\n"),
        )

    var fs_path = safe_join(root, req.path)
    var p = Path(fs_path)

    if not p.exists():
        return build_response_text(
            String("404 Not Found"),
            String("text/plain; charset=utf-8"),
            String("404 not found\n"),
        )

    if p.is_dir():
        # Try index.html first.
        var index = Path(fs_path + "/index.html")
        if index.exists() and index.is_file():
            try:
                var bytes = index.read_bytes()
                return build_response(
                    String("200 OK"),
                    mime_for(String("index.html")),
                    bytes,
                )
            except:
                pass

        if not allow_listing:
            return build_response_text(
                String("403 Forbidden"),
                String("text/plain; charset=utf-8"),
                String("403 directory listing disabled\n"),
            )

        try:
            var entries = p.listdir()
            var html = directory_listing_html(req.path, entries)
            return build_response_text(
                String("200 OK"),
                String("text/html; charset=utf-8"),
                html,
            )
        except:
            return build_response_text(
                String("500 Internal Server Error"),
                String("text/plain; charset=utf-8"),
                String("500 could not list directory\n"),
            )

    # Regular file.
    try:
        var bytes = p.read_bytes()
        return build_response(String("200 OK"), mime_for(fs_path), bytes)
    except:
        return build_response_text(
            String("500 Internal Server Error"),
            String("text/plain; charset=utf-8"),
            String("500 could not read file\n"),
        )


# ── CLI / config parsing ─────────────────────────────────────────────────
struct ServeConfig(Copyable, Movable):
    var root: String
    var port: Int
    var allow_listing: Bool

    def __init__(out self):
        self.root = String(".")
        self.port = DEFAULT_PORT
        self.allow_listing = True


def print_usage():
    print("Usage: serve [--port N] [--listing | --no-listing] [path]")
    print("")
    print("  path             Directory to serve (default: \".\")")
    print("  --port N         Port to bind (default: 8000)")
    print("  --listing        Generate HTML index for directories (default)")
    print("  --no-listing     Refuse to enumerate directories without index.html")
    print("  -h, --help       Show this message")


def parse_args() raises -> ServeConfig:
    var cfg = ServeConfig()
    var args = argv()
    var i: Int = 1
    while i < len(args):
        var a = String(args[i])
        if a == "-h" or a == "--help":
            print_usage()
            return cfg^
        elif a == "--port":
            if i + 1 >= len(args):
                raise Error("--port requires a number")
            cfg.port = atol(String(args[i + 1]))
            i += 2
        elif a == "--listing":
            cfg.allow_listing = True
            i += 1
        elif a == "--no-listing":
            cfg.allow_listing = False
            i += 1
        elif a.startswith("--"):
            raise Error("unknown flag: " + a)
        else:
            cfg.root = a
            i += 1
    return cfg^


# ── Demo entry point ─────────────────────────────────────────────────────
# Standalone CLI loop. Not an entry point in the bundle; Phase 2 wires
# this into `App.run()`. Kept here as the reference implementation.
def _demo() raises:
    var cfg: ServeConfig
    try:
        cfg = parse_args()
    except e:
        print("[serve] error:", String(e))
        print_usage()
        return

    # Resolve root: must exist and be a directory.
    var root_path = Path(cfg.root)
    if not root_path.exists():
        print("[serve] error: path does not exist:", cfg.root)
        return
    if not root_path.is_dir():
        print("[serve] error: path is not a directory:", cfg.root)
        return

    print("┌──────────────────────────────────────────────────┐")
    print("│  mojo-serve v0.1.0 · Apache-2.0                  │")
    print("└──────────────────────────────────────────────────┘")
    print("[serve] root =", cfg.root, " · port =", cfg.port,
          " · listing =", "on" if cfg.allow_listing else "off")

    var sock = socket_create()
    if Int(sock) < 0:
        print("[fatal] socket() failed")
        return
    _ = socket_reuseaddr(sock)
    var addr = make_sockaddr_in(cfg.port)
    if not socket_bind(sock, addr):
        print("[fatal] bind() failed on port", cfg.port)
        socket_close(sock)
        return
    if not socket_listen(sock):
        print("[fatal] listen() failed")
        socket_close(sock)
        return

    print("[serve] listening on http://0.0.0.0:" + String(cfg.port) + "/")
    print("[serve] try:  curl http://localhost:" + String(cfg.port) + "/")

    while True:
        var client = socket_accept(sock)
        if Int(client) < 0:
            continue
        var raw = read_request(client)
        if len(raw) == 0:
            socket_close(client)
            continue
        var req = parse_request(raw)
        # Access-log line.
        print("[serve]", req.method, req.path)
        var resp = handle_static(cfg.root, req, cfg.allow_listing)
        write_all(client, resp)
        socket_close(client)
