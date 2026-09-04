"""Phase 2.1 — router tests.

Exercises RoutePattern parsing/matching, Params extraction, and
Router.resolve including 405 (method-not-allowed) handling. Does NOT
touch sockets — the router is pure data.
"""

from baldr.router import (
    Params, RoutePattern, Router, Match,
    ROUTE_OK, ROUTE_METHOD_NOT_ALLOWED, ROUTE_NOT_FOUND,
    SEG_LITERAL, SEG_PARAM,
)


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

    # ── RoutePattern parsing ───────────────────────────────────────────
    var pat = RoutePattern(String("/users/{id}/posts/{pid}"))
    r.check("pattern has 4 segments", len(pat.segments) == 4)
    r.check("seg0 literal users", pat.segments[0].kind == SEG_LITERAL and pat.segments[0].value == "users")
    r.check("seg1 param id", pat.segments[1].kind == SEG_PARAM and pat.segments[1].value == "id")
    r.check("seg2 literal posts", pat.segments[2].kind == SEG_LITERAL and pat.segments[2].value == "posts")
    r.check("seg3 param pid", pat.segments[3].kind == SEG_PARAM and pat.segments[3].value == "pid")

    # ── RoutePattern matching ──────────────────────────────────────────
    var m1 = pat.match(String("/users/42/posts/7"))
    r.check("match /users/42/posts/7", m1 is not None)
    if m1 is not None:
        var p = m1.value().copy()
        r.check("param id == 42", p.get(String("id")) == "42")
        r.check("param pid == 7", p.get(String("pid")) == "7")
        r.check("get_int id == 42", p.get_int(String("id")) == 42)
        r.check("absent param -> default", p.get(String("missing"), String("x")) == "x")
        r.check("absent get_int -> default", p.get_int(String("missing"), -1) == -1)
        r.check("is_empty False", not p.is_empty())
        r.check("len == 2", len(p) == 2)

    var m2 = pat.match(String("/users/42"))
    r.check("no match wrong arity", m2 is None)
    var m3 = pat.match(String("/users/42/posts/7/extra"))
    r.check("no match extra segment", m3 is None)
    var m4 = pat.match(String("/accounts/42/posts/7"))
    r.check("no match literal mismatch", m4 is None)
    var m5 = pat.match(String("/users/42/posts/7/"))  # trailing slash tolerated
    r.check("match trailing slash", m5 is not None)

    # ── bad Int raises ─────────────────────────────────────────────────
    var pat2 = RoutePattern(String("/items/{n}"))
    var m6 = pat2.match(String("/items/abc"))
    var raised = False
    if m6 is not None:
        try:
            _ = m6.value().get_int(String("n"))
        except:
            raised = True
    r.check("get_int raises on non-numeric", raised)

    # ── Router.resolve: OK, 405, 404 ───────────────────────────────────
    var router = Router()
    router.get(String("/"), String("index"))
    router.get(String("/users/{id}"), String("user_show"))
    router.post(String("/users"), String("user_create"))
    router.delete(String("/users/{id}"), String("user_delete"))

    var ok = router.resolve(String("GET"), String("/users/42"))
    r.check("resolve GET /users/42 -> OK", ok.status == ROUTE_OK)
    r.check("  name user_show", ok.name == "user_show")
    r.check("  param id == 42", ok.params.get(String("id")) == "42")

    var ok2 = router.resolve(String("POST"), String("/users"))
    r.check("resolve POST /users -> OK", ok2.status == ROUTE_OK and ok2.name == "user_create")

    var ok3 = router.resolve(String("GET"), String("/"))
    r.check("resolve GET / -> OK index", ok3.status == ROUTE_OK and ok3.name == "index")

    var mna = router.resolve(String("PUT"), String("/users/42"))
    r.check("resolve PUT /users/42 -> 405", mna.status == ROUTE_METHOD_NOT_ALLOWED)
    r.check("  allowed lists GET, DELETE", mna.allowed == "GET, DELETE" or mna.allowed == "DELETE, GET")

    var nf = router.resolve(String("GET"), String("/nope"))
    r.check("resolve GET /nope -> 404", nf.status == ROUTE_NOT_FOUND)

    var mna2 = router.resolve(String("DELETE"), String("/"))
    r.check("resolve DELETE / -> 405 (only GET)", mna2.status == ROUTE_METHOD_NOT_ALLOWED and mna2.allowed == "GET")

    # ── empty Params ───────────────────────────────────────────────────
    var empty = Params()
    r.check("empty is_empty True", empty.is_empty())
    r.check("empty get default", empty.get(String("x"), String("d")) == "d")
    r.check("empty len 0", len(empty) == 0)

    r.summary()
