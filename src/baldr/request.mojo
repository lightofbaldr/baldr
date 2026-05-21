"""baldr.Request — request representation passed to every handler.

A Phase-2 public type. The vendored `serve.Request` is the minimal
internal struct used by static-file dispatch; `baldr.Request` is the
richer, user-facing type that includes headers, body, and query string.
"""

from std.collections import Dict
from .json import JsonValue, parse as json_parse


struct Request(Copyable, Movable):
    """HTTP request as received by a handler."""
    var method: String
    var path: String
    var query: String
    var body: String
    var headers: Dict[String, String]

    def __init__(out self):
        self.method = String("GET")
        self.path = String("/")
        self.query = String()
        self.body = String()
        self.headers = Dict[String, String]()

    def __init__(
        out self,
        method: String,
        path: String,
        query: String,
        body: String,
        var headers: Dict[String, String],
    ):
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.headers = headers^

    def header(self, name: String) -> String:
        """Case-insensitive lookup. Returns empty string if absent."""
        var lower = _lowercase(name)
        for entry in self.headers.items():
            if _lowercase(entry.key) == lower:
                return entry.value
        return String()

    def form(self) raises -> Dict[String, String]:
        """Parse application/x-www-form-urlencoded body. Empty dict on
        malformed input — handlers can detect via empty values."""
        return _parse_form(self.body)

    def json(self) raises -> JsonValue:
        """Parse the request body as JSON. Raises on malformed."""
        return json_parse(self.body)


def _lowercase(s: String) -> String:
    var out = String()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            c += 32
        out += chr(c)
    return out^


def _parse_form(body: String) raises -> Dict[String, String]:
    """Parse `a=1&b=2` form-encoded text."""
    var out = Dict[String, String]()
    if body.byte_length() == 0:
        return out^
    var parts = body.split(String("&"))
    for var p in parts:
        var ps = String(p)
        var eq = ps.find(String("="))
        if eq < 0:
            out[_url_decode(ps)] = String()
        else:
            var key = _url_decode(String(ps[byte=0:eq]))
            var val = _url_decode(String(ps[byte=eq + 1:]))
            out[key] = val
    return out^


def _url_decode(s: String) -> String:
    """Decode %XX percent-escapes and `+` → space. Quietly leaves stray %X."""
    var out = String()
    var b = s.as_bytes()
    var n = len(b)
    var i: Int = 0
    while i < n:
        var c = b[i]
        if c == UInt8(43):  # '+'
            out += " "
            i += 1
        elif c == UInt8(37) and i + 2 < n:  # '%'
            var hi = _hex_digit(b[i + 1])
            var lo = _hex_digit(b[i + 2])
            if hi >= 0 and lo >= 0:
                out += chr(hi * 16 + lo)
                i += 3
            else:
                out += chr(Int(c))
                i += 1
        else:
            out += chr(Int(c))
            i += 1
    return out^


def _hex_digit(c: UInt8) -> Int:
    var x = Int(c)
    if x >= 48 and x <= 57:
        return x - 48
    if x >= 65 and x <= 70:
        return x - 65 + 10
    if x >= 97 and x <= 102:
        return x - 97 + 10
    return -1


# ── Parsing raw HTTP bytes into a Request ─────────────────────────────────
def parse_request(req_bytes: List[UInt8]) raises -> Request:
    """Parse a raw HTTP/1.1 request into a Request.

    Returns a Request with sensible defaults on partial input; handlers
    should not normally see malformed data because the read loop
    accumulates the full head before dispatch.
    """
    var r = Request()
    var n = len(req_bytes)
    if n == 0:
        return r^

    # Method.
    var i: Int = 0
    while i < n and req_bytes[i] != UInt8(32):
        i += 1
    var method = String()
    for j in range(i):
        method += chr(Int(req_bytes[j]))
    r.method = method^
    if i >= n:
        return r^
    i += 1

    # Path + query.
    var path_start = i
    while i < n and req_bytes[i] != UInt8(32) and req_bytes[i] != UInt8(13):
        i += 1
    var full_path = String()
    for j in range(path_start, i):
        full_path += chr(Int(req_bytes[j]))
    var qmark = full_path.find(String("?"))
    if qmark < 0:
        r.path = full_path
        r.query = String()
    else:
        r.path = String(full_path[byte=0:qmark])
        r.query = String(full_path[byte=qmark + 1:])

    # Skip "HTTP/1.1\r\n".
    while i < n and req_bytes[i] != UInt8(10):
        i += 1
    if i < n:
        i += 1  # past LF

    # Headers up to blank CRLF.
    var content_length: Int = 0
    while i < n:
        # End of headers when we see CRLF or LF immediately.
        if i < n and req_bytes[i] == UInt8(13):
            i += 1
            if i < n and req_bytes[i] == UInt8(10):
                i += 1
            break
        if i < n and req_bytes[i] == UInt8(10):
            i += 1
            break

        # Read one header line.
        var line = String()
        while i < n and req_bytes[i] != UInt8(13) and req_bytes[i] != UInt8(10):
            line += chr(Int(req_bytes[i]))
            i += 1
        # Skip line terminator.
        if i < n and req_bytes[i] == UInt8(13):
            i += 1
        if i < n and req_bytes[i] == UInt8(10):
            i += 1

        var colon = line.find(String(":"))
        if colon > 0:
            var k = String(line[byte=0:colon])
            var v_start = colon + 1
            # Trim leading whitespace from value.
            var vb = line.as_bytes()
            while v_start < len(vb) and (vb[v_start] == UInt8(32) or vb[v_start] == UInt8(9)):
                v_start += 1
            var v = String(line[byte=v_start:])
            r.headers[k] = v
            if _lowercase(k) == "content-length":
                try:
                    content_length = atol(v)
                except:
                    content_length = 0

    # Body — exactly Content-Length bytes if declared, else remainder.
    var body_end = i + content_length if content_length > 0 else n
    if body_end > n:
        body_end = n
    var body = String()
    for j in range(i, body_end):
        body += chr(Int(req_bytes[j]))
    r.body = body^

    return r^
