"""baldr.router — path-pattern routing with named params.

Phase 2.1 — routing + params. A `Router` holds route entries
(method + pattern + name) as pure data and resolves an incoming
(method, path) to a `Match` carrying extracted path params, with
405-awareness. Route patterns support `{param}` string segments and
`{param:int}` signed-decimal segments, e.g. `/users/{id:int}`.

Mojo 1.0 cannot store a heterogeneous list of `def`-typed handlers, so
the Router resolves to a route *name* + `Params`; `App.run_routes`
dispatches to a single `RouteHandler` that switches on the matched
name. This is the "routes are data, handler is a trait" fallback
endorsed in docs/DESIGN.md — it centralizes path matching + param
extraction + 405 handling without depending on storable function
pointers.
"""

from std.collections import Dict


# ── Params ────────────────────────────────────────────────────────────────
struct Params(Copyable, Movable, Sized):
    """Path-parameter bag extracted from a matched route."""
    var data: Dict[String, String]

    def __init__(out self):
        self.data = Dict[String, String]()

    def __init__(out self, var data: Dict[String, String]):
        self.data = data^

    def has(self, key: String) -> Bool:
        return key in self.data

    def get(self, key: String, default: String = String()) -> String:
        for entry in self.data.items():
            if entry.key == key:
                return entry.value
        return default

    def get_int(self, key: String, default: Int = 0) raises -> Int:
        """Parse a param as Int. Returns `default` if absent; raises on
        a present-but-non-numeric value."""
        var raw = String()
        var found = False
        for entry in self.data.items():
            if entry.key == key:
                raw = entry.value
                found = True
                break
        if not found:
            return default
        if not _is_decimal_int(raw):
            raise Error(String("baldr: param '") + key + "' is not an Int: '" + raw + "'")
        try:
            return atol(raw)
        except:
            raise Error(String("baldr: param '") + key + "' is not an Int: '" + raw + "'")

    def get_int_or(self, key: String, default: Int) -> Int:
        """Parse a param as Int, returning `default` when absent or invalid."""
        try:
            return self.get_int(key, default)
        except:
            return default

    def is_empty(self) -> Bool:
        return len(self.data) == 0

    def __len__(self) -> Int:
        return len(self.data)


# ── Route pattern segments ────────────────────────────────────────────────
comptime SEG_LITERAL = 0
comptime SEG_PARAM = 1
comptime SEG_PARAM_INT = 2


def _is_decimal_int(value: String) -> Bool:
    """True for one-or-more decimal digits with an optional leading sign."""
    var bytes = value.as_bytes()
    if len(bytes) == 0:
        return False
    var start = 0
    if bytes[0] == UInt8(43) or bytes[0] == UInt8(45):  # '+' / '-'
        start = 1
    if start == len(bytes):
        return False
    for i in range(start, len(bytes)):
        if bytes[i] < UInt8(48) or bytes[i] > UInt8(57):
            return False
    return True


struct Segment(Copyable, Movable):
    """One segment of a route pattern.

    `kind` is SEG_LITERAL, SEG_PARAM, or SEG_PARAM_INT; `value` is the
    literal text or the param name.
    """
    var kind: Int
    var value: String

    def __init__(out self, kind: Int, value: String):
        self.kind = kind
        self.value = value


struct RoutePattern(Copyable, Movable):
    """A parsed route pattern, e.g. `/users/{id}/posts/{pid}`.

    Segments are stored without leading/trailing slashes; matching is
    slash-insensitive (trailing slash on the request path is tolerated)."""
    var segments: List[Segment]
    var source: String

    def __init__(out self, pattern: String):
        self.segments = List[Segment]()
        self.source = pattern
        var parts = pattern.split(String("/"))
        for var p in parts:
            var ps = String(p)
            if ps.byte_length() == 0:
                continue
            if ps[byte=0:1] == "{" and ps[byte=ps.byte_length() - 1:ps.byte_length()] == "}":
                var name = String(ps[byte=1:ps.byte_length() - 1])
                var kind = SEG_PARAM
                var colon = name.rfind(String(":"))
                if colon > 0 and String(name[byte=colon + 1:]) == "int":
                    var typed_name = String(name[byte=0:colon])
                    name = typed_name^
                    kind = SEG_PARAM_INT
                self.segments.append(Segment(kind, name))
            else:
                self.segments.append(Segment(SEG_LITERAL, ps))

    def match(self, path: String) -> Optional[Params]:
        """Return extracted Params if `path` matches, else None."""
        var path_parts = path.split(String("/"))
        var path_segs = List[String]()
        for var p in path_parts:
            var ps = String(p)
            if ps.byte_length() > 0:
                path_segs.append(ps)
        if len(path_segs) != len(self.segments):
            return Optional[Params](None)

        var params = Params()
        for i in range(len(self.segments)):
            ref seg = self.segments[i]
            var pv = path_segs[i]
            if seg.kind == SEG_PARAM:
                params.data[seg.value] = pv
            elif seg.kind == SEG_PARAM_INT:
                if not _is_decimal_int(pv):
                    return Optional[Params](None)
                params.data[seg.value] = pv
            else:
                if seg.value != pv:
                    return Optional[Params](None)
        return Optional[Params](params^)


# ── Route entries + match result ──────────────────────────────────────────
struct RouteEntry(Copyable, Movable):
    var method: String
    var pattern: RoutePattern
    var name: String

    def __init__(out self, method: String, var pattern: RoutePattern, name: String):
        self.method = method
        self.pattern = pattern^
        self.name = name


comptime ROUTE_OK = 0
comptime ROUTE_METHOD_NOT_ALLOWED = 1
comptime ROUTE_NOT_FOUND = 2


struct Match(Copyable, Movable):
    """Result of Router.resolve.

    `status` is ROUTE_OK / ROUTE_METHOD_NOT_ALLOWED / ROUTE_NOT_FOUND.
    On OK, `name` + `params` describe the match. On METHOD_NOT_ALLOWED,
    `allowed` lists the comma-separated methods that DO match the path
    (for the `Allow` response header)."""
    var status: Int
    var name: String
    var params: Params
    var allowed: String

    def __init__(out self):
        self.status = ROUTE_NOT_FOUND
        self.name = String()
        self.params = Params()
        self.allowed = String()

    @staticmethod
    def not_found() -> Match:
        var m = Match()
        m.status = ROUTE_NOT_FOUND
        return m^


struct Router(Copyable, Movable):
    """A table of route entries. Resolves (method, path) to a Match."""
    var entries: List[RouteEntry]

    def __init__(out self):
        self.entries = List[RouteEntry]()

    def route(mut self, method: String, pattern: String, name: String):
        """Register a route. `name` is the key the handler dispatches on."""
        self.entries.append(RouteEntry(method, RoutePattern(pattern), name))

    def get(mut self, pattern: String, name: String):
        self.route(String("GET"), pattern, name)

    def post(mut self, pattern: String, name: String):
        self.route(String("POST"), pattern, name)

    def put(mut self, pattern: String, name: String):
        self.route(String("PUT"), pattern, name)

    def delete(mut self, pattern: String, name: String):
        self.route(String("DELETE"), pattern, name)

    def patch(mut self, pattern: String, name: String):
        self.route(String("PATCH"), pattern, name)

    def head(mut self, pattern: String, name: String):
        self.route(String("HEAD"), pattern, name)

    def resolve(self, method: String, path: String) -> Match:
        """Resolve (method, path). Path matches are checked across all
        methods so a path match with a different method yields 405."""
        var path_matched = False
        var allowed = List[String]()
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            var maybe = e.pattern.match(path)
            if maybe is None:
                continue
            path_matched = True
            # Avoid duplicate methods in the Allow list.
            var already = False
            for j in range(len(allowed)):
                if allowed[j] == e.method:
                    already = True
                    break
            if not already:
                allowed.append(e.method)
            if e.method == method:
                var m = Match()
                m.status = ROUTE_OK
                m.name = e.name
                m.params = maybe.value().copy()
                return m^

        if path_matched:
            var m = Match()
            m.status = ROUTE_METHOD_NOT_ALLOWED
            var joined = String()
            for j in range(len(allowed)):
                if j > 0:
                    joined += ", "
                joined += allowed[j]
            m.allowed = joined
            return m^
        return Match.not_found()
