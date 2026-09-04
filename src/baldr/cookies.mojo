"""baldr.cookies — HTTP cookie parsing and Set-Cookie building.

Phase 2.3 — request/response enrichment (cookies).

`Cookie` / `SetCookie` are pure data structs; `parse_cookies` reads a
`Cookie:` request header into a `Dict`, and `SetCookie.to_header()` renders
a `Set-Cookie` response header. `Response.with_cookie` / `add_cookie`
append Set-Cookie headers (multiple are allowed and order-preserving).

No external deps — pure Mojo string parsing over the existing `Request` /
`Response` types.
"""

from std.collections import Dict
from .response import Response


def _sanitize_cookie(s: String, is_name: Bool) -> String:
    """Drop octets that would break `Set-Cookie` framing so an attacker-controlled
    cookie name/value cannot inject `;`-separated attributes (Domain/Path/HttpOnly…)
    or fold a second cookie with `,`. CR/LF/NUL are additionally stripped downstream
    at the response render choke point. Multi-byte UTF-8 is preserved (only single
    ASCII bytes are filtered), mirroring response._strip_header_controls."""
    var out = String()
    for cp in s.codepoint_slices():
        var cb = cp.as_bytes()
        if len(cb) == 1:
            var c = cb[0]
            if c < 0x20 or c == 0x7F or c == 0x3B or c == 0x2C:  # CTLs, ';', ','
                continue
            if is_name and (c == 0x3D or c == 0x20):             # '=' / SP invalid in a name token
                continue
        out += String(cp)
    return out^


struct Cookie(Copyable, Movable, Sized):
    """A single parsed request cookie (name + value)."""
    var name: String
    var value: String

    def __init__(out self, name: String, value: String):
        self.name = name
        self.value = value

    def __len__(self) -> Int:
        return 2


struct SetCookie(Copyable, Movable):
    """A Set-Cookie response directive. Only `name`/`value` are required;
    the rest are optional attributes rendered only when set."""
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: String        # HTTP-date string, e.g. "Wed, 21 Oct 2026 07:28:00 GMT"
    var max_age: Int           # seconds; -1 = not set
    var http_only: Bool
    var secure: Bool
    var same_site: String      # "Strict" | "Lax" | "None" | "" (omit)

    def __init__(out self, name: String, value: String):
        self.name = name
        self.value = value
        self.domain = String()
        self.path = String()
        self.expires = String()
        self.max_age = -1
        self.http_only = False
        self.secure = False
        self.same_site = String()

    def with_domain(self, domain: String) -> SetCookie:
        var c = self.copy()
        c.domain = domain
        return c^

    def with_path(self, path: String) -> SetCookie:
        var c = self.copy()
        c.path = path
        return c^

    def with_expires(self, expires: String) -> SetCookie:
        var c = self.copy()
        c.expires = expires
        return c^

    def with_max_age(self, max_age: Int) -> SetCookie:
        var c = self.copy()
        c.max_age = max_age
        return c^

    def with_http_only(self) -> SetCookie:
        var c = self.copy()
        c.http_only = True
        return c^

    def with_secure(self) -> SetCookie:
        var c = self.copy()
        c.secure = True
        return c^

    def same_site_strict(self) -> SetCookie:
        var c = self.copy()
        c.same_site = String("Strict")
        return c^

    def same_site_lax(self) -> SetCookie:
        var c = self.copy()
        c.same_site = String("Lax")
        return c^

    def same_site_none(self) -> SetCookie:
        var c = self.copy()
        c.same_site = String("None")
        return c^

    def to_header(self) -> String:
        """Render the full `Set-Cookie:` header value (without the field name).
        name/value are sanitized (RFC 6265 cookie-octet) so an attacker-controlled
        value cannot inject `;` attributes or fold a second cookie with `,`."""
        var h = _sanitize_cookie(self.name, True) + "=" + _sanitize_cookie(self.value, False)
        if self.domain.byte_length() > 0:
            h += "; Domain=" + self.domain
        if self.path.byte_length() > 0:
            h += "; Path=" + self.path
        if self.expires.byte_length() > 0:
            h += "; Expires=" + self.expires
        if self.max_age >= 0:
            h += "; Max-Age=" + String(self.max_age)
        if self.same_site.byte_length() > 0:
            h += "; SameSite=" + self.same_site
        if self.secure:
            h += "; Secure"
        if self.http_only:
            h += "; HttpOnly"
        return h^


def parse_cookies(header_value: String) -> Dict[String, String]:
    """Parse a `Cookie:` request header value (`a=1; b=2`) into a dict.

    Quietly skips malformed segments (no `=`); last value wins on duplicate
    names. Empty input yields an empty dict.
    """
    var out = Dict[String, String]()
    if header_value.byte_length() == 0:
        return out^
    var parts = header_value.split(String(";"))
    for var p in parts:
        var ps = String(p)
        # trim leading space
        var b = ps.as_bytes()
        var start: Int = 0
        var n = len(b)
        while start < n and (b[start] == UInt8(32) or b[start] == UInt8(9)):
            start += 1
        if start >= n:
            continue
        var trimmed = String(ps[byte=start:])
        var eq = trimmed.find(String("="))
        if eq <= 0:
            continue
        var k = String(trimmed[byte=0:eq])
        var v = String(trimmed[byte=eq + 1:])
        out[k] = v
    return out^
