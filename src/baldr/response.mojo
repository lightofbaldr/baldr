"""baldr.Response — response builder returned from every handler.

Static constructors cover the common shapes; `.with_header()` chains.
`to_bytes()` renders the full HTTP/1.1 response (status line + headers
+ body) for write_all() on the socket.
"""

from std.pathlib import Path
from .json import JsonValue, dumps as json_dumps


struct Header(Copyable, Movable):
    """Single response header. Stored as an ordered list so users
    can append multiple Set-Cookie entries and preserve order."""
    var key: String
    var value: String

    def __init__(out self, key: String, value: String):
        self.key = key
        self.value = value


struct Response(Copyable, Movable):
    """HTTP/1.1 response."""
    var status: Int
    var body: List[UInt8]
    var headers: List[Header]

    def __init__(out self):
        self.status = 200
        self.body = List[UInt8]()
        self.headers = List[Header]()

    def __init__(out self, status: Int, var body: List[UInt8], var headers: List[Header]):
        self.status = status
        self.body = body^
        self.headers = headers^

    @staticmethod
    def text(body: String, status: Int = 200) -> Response:
        var r = Response()
        r.status = status
        r.body = _string_to_bytes(body)
        r.headers.append(Header(String("Content-Type"), String("text/plain; charset=utf-8")))
        return r^

    @staticmethod
    def html(body: String, status: Int = 200) -> Response:
        var r = Response()
        r.status = status
        r.body = _string_to_bytes(body)
        r.headers.append(Header(String("Content-Type"), String("text/html; charset=utf-8")))
        return r^

    @staticmethod
    def json(value: JsonValue, status: Int = 200) -> Response:
        var r = Response()
        r.status = status
        r.body = _string_to_bytes(json_dumps(value))
        r.headers.append(Header(String("Content-Type"), String("application/json; charset=utf-8")))
        return r^

    @staticmethod
    def redirect(location: String, status: Int = 302) -> Response:
        var r = Response()
        r.status = status
        r.headers.append(Header(String("Location"), location))
        r.headers.append(Header(String("Content-Type"), String("text/plain; charset=utf-8")))
        r.body = _string_to_bytes(String("Redirecting to ") + location + "\n")
        return r^

    @staticmethod
    def file(path: String) raises -> Response:
        var p = Path(path)
        if not p.exists() or not p.is_file():
            var nr = Response()
            nr.status = 404
            nr.body = _string_to_bytes(String("404 not found\n"))
            nr.headers.append(Header(String("Content-Type"), String("text/plain; charset=utf-8")))
            return nr^
        var bytes = p.read_bytes()
        var r = Response()
        r.status = 200
        r.body = bytes^
        r.headers.append(Header(String("Content-Type"), _mime_for(path)))
        return r^

    def with_header(self, key: String, value: String) -> Response:
        """Returns a new Response with the header appended. Chainable."""
        var hs = self.headers.copy()
        hs.append(Header(key, value))
        return Response(self.status, self.body.copy(), hs^)

    def to_bytes(self) -> List[UInt8]:
        """Render the full HTTP/1.1 response to a byte buffer."""
        var head = String("HTTP/1.1 ") + _status_text(self.status) + "\r\n"
        head += "Content-Length: " + String(len(self.body)) + "\r\n"
        head += "Server: baldr/0.1\r\n"
        head += "Connection: close\r\n"
        for i in range(len(self.headers)):
            ref h = self.headers[i]
            head += h.key + ": " + h.value + "\r\n"
        head += "\r\n"

        var head_bytes = head.as_bytes()
        var out = List[UInt8](capacity=len(head_bytes) + len(self.body))
        for i in range(len(head_bytes)):
            out.append(head_bytes[i])
        for i in range(len(self.body)):
            out.append(self.body[i])
        return out^


def _string_to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _status_text(code: Int) -> String:
    if code == 200: return String("200 OK")
    if code == 201: return String("201 Created")
    if code == 204: return String("204 No Content")
    if code == 301: return String("301 Moved Permanently")
    if code == 302: return String("302 Found")
    if code == 303: return String("303 See Other")
    if code == 304: return String("304 Not Modified")
    if code == 307: return String("307 Temporary Redirect")
    if code == 308: return String("308 Permanent Redirect")
    if code == 400: return String("400 Bad Request")
    if code == 401: return String("401 Unauthorized")
    if code == 403: return String("403 Forbidden")
    if code == 404: return String("404 Not Found")
    if code == 405: return String("405 Method Not Allowed")
    if code == 409: return String("409 Conflict")
    if code == 413: return String("413 Payload Too Large")
    if code == 422: return String("422 Unprocessable Entity")
    if code == 429: return String("429 Too Many Requests")
    if code == 500: return String("500 Internal Server Error")
    if code == 502: return String("502 Bad Gateway")
    if code == 503: return String("503 Service Unavailable")
    if code == 504: return String("504 Gateway Timeout")
    return String(code) + " Status"


def _mime_for(path: String) -> String:
    """Tiny MIME map covering common web assets."""
    var lower = path
    var dot = lower.rfind(String("."))
    if dot < 0:
        return String("application/octet-stream")
    var ext = String(lower[byte=dot:])
    if ext == ".html" or ext == ".htm": return String("text/html; charset=utf-8")
    if ext == ".css":  return String("text/css; charset=utf-8")
    if ext == ".js":   return String("application/javascript; charset=utf-8")
    if ext == ".json": return String("application/json; charset=utf-8")
    if ext == ".svg":  return String("image/svg+xml")
    if ext == ".png":  return String("image/png")
    if ext == ".jpg" or ext == ".jpeg": return String("image/jpeg")
    if ext == ".gif":  return String("image/gif")
    if ext == ".webp": return String("image/webp")
    if ext == ".ico":  return String("image/x-icon")
    if ext == ".woff": return String("font/woff")
    if ext == ".woff2": return String("font/woff2")
    if ext == ".txt":  return String("text/plain; charset=utf-8")
    if ext == ".pdf":  return String("application/pdf")
    return String("application/octet-stream")
