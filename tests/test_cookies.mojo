"""Phase 2.3 — request/response enrichment tests (cookies + SSE)."""

from std.collections import Dict, List

from baldr.request import Request, parse_request
from baldr.response import Response
from baldr.cookies import SetCookie, parse_cookies


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


def main() raises:
    var r = Runner()

    # ── parse_cookies ──────────────────────────────────────────────────
    var c = parse_cookies(String("session=abc; theme=dark; user=42"))
    r.check("3 cookies parsed", len(c) == 3)
    r.check("session == abc", c["session"] == "abc")
    r.check("theme == dark", c["theme"] == "dark")
    r.check("user == 42", c["user"] == "42")

    var c2 = parse_cookies(String("a=1; b=hello world; empty="))
    r.check("value with space", c2["b"] == "hello world")
    r.check("empty value", c2["empty"] == "")
    r.check("empty header -> 0", len(parse_cookies(String())) == 0)
    r.check("malformed skipped", len(parse_cookies(String("good=1; bad; nogood"))) == 1)

    # ── SetCookie rendering ─────────────────────────────────────────────
    var sc = SetCookie(String("sid"), String("xyz"))
    var h = sc.to_header()
    r.check("basic set-cookie", h == "sid=xyz")

    var sc2 = SetCookie(String("token"), String("abc")).with_path(String("/")).with_max_age(3600).with_http_only().with_secure().same_site_lax()
    var h2 = sc2.to_header()
    r.check("set-cookie has Path=/", h2.find(String("Path=/")) > 0)
    r.check("set-cookie has Max-Age=3600", h2.find(String("Max-Age=3600")) > 0)
    r.check("set-cookie has HttpOnly", h2.find(String("HttpOnly")) > 0)
    r.check("set-cookie has Secure", h2.find(String("Secure")) > 0)
    r.check("set-cookie has SameSite=Lax", h2.find(String("SameSite=Lax")) > 0)

    # ── Set-Cookie injection hardening ─────────────────────────────────
    var inj = SetCookie(String("sid"), String("x; HttpOnly; Domain=evil.com")).to_header()
    r.check("value ';' stripped (no attribute injection)", inj.count(String(";")) == 0)
    r.check("value prefix preserved", inj.find(String("sid=x")) == 0)
    var injn = SetCookie(String("a=b;c"), String("v")).to_header()
    r.check("name '=' and ';' stripped", injn.find(String("abc=v")) == 0)

    # ── Request.cookies / cookie ────────────────────────────────────────
    var req = Request(String("GET"), String("/"), String(), String(), Dict[String, String]())
    req.headers[String("Cookie")] = String("foo=bar; baz=qux")
    r.check("req.cookies() parses", req.cookies()["foo"] == "bar")
    r.check("req.cookie() lookup", req.cookie(String("baz")) == "qux")
    r.check("req.cookie() default", req.cookie(String("missing"), String("none")) == "none")

    # ── Response.with_cookie / add_cookie ──────────────────────────────
    var resp = Response.text(String("ok"))
    var with_c = resp.with_cookie(SetCookie(String("a"), String("1")))
    var scount = 0
    for i in range(len(with_c.headers)):
        if with_c.headers[i].key == "Set-Cookie":
            scount += 1
    r.check("with_cookie appends 1 Set-Cookie", scount == 1)

    var resp2 = Response.text(String("ok"))
    resp2.add_cookie(SetCookie(String("first"), String("1")))
    resp2.add_cookie(SetCookie(String("second"), String("2")))
    var scount2 = 0
    for i in range(len(resp2.headers)):
        if resp2.headers[i].key == "Set-Cookie":
            scount2 += 1
    r.check("add_cookie appends multiple (order-preserving)", scount2 == 2)

    # ── Response.sse ────────────────────────────────────────────────────
    var events = List[String]()
    events.append(String("hello"))
    events.append(String("world"))
    var sse = Response.sse(events)
    r.check("sse status 200", sse.status == 200)
    var ctype = String()
    for i in range(len(sse.headers)):
        if sse.headers[i].key == "Content-Type":
            ctype = sse.headers[i].value
    r.check("sse content-type", ctype == "text/event-stream; charset=utf-8")
    # body should be "data: hello\n\ndata: world\n\n"
    var body = String()
    for i in range(len(sse.body)):
        body += chr(Int(sse.body[i]))
    r.check("sse body has two data lines", body.count(String("data:")) == 2)
    r.check("sse body double-newline separators", body.count(String("\n\n")) == 2)

    r.summary()
