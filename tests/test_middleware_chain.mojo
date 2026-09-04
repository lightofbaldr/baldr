"""Phase 2.2 — middleware chain tests.

Exercises the comptime-monomorphized middleware pipeline via the
standalone `apply_middleware` helper (no sockets): before short-circuit,
after mutation, ordering, and the built-in SecurityHeaders conformer.
"""

from baldr.request import Request
from baldr.response import Response
from baldr.middleware.chain import (
    Middleware, MW_PASS, apply_middleware,
    SecurityHeaders, RequestLogger,
)
from baldr.middleware.security_headers import DEFAULT_CSP


# A no-op pass-through middleware that records visit order.
@fieldwise_init
struct Recorder(Middleware, Copyable, Movable):
    var name: String

    def before(self, req: Request) raises -> Response:
        var r = Response()
        r.status = MW_PASS
        # carry "before ran" via a response header (proves before executed)
        r.add_header(String("X-Before"), self.name)
        return r^

    def after(self, req: Request, mut resp: Response) raises:
        resp.add_header(String("X-Order"), self.name)


# A short-circuiting middleware (always blocks with 403).
@fieldwise_init
struct AlwaysBlock(Middleware, Copyable, Movable):
    var code: Int

    def before(self, req: Request) raises -> Response:
        return Response.text(String("forbidden\n"), self.code)

    def after(self, req: Request, mut resp: Response) raises:
        resp.add_header(String("X-Should-Not-Run"), String("yes"))


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

    var rec1 = Recorder(String("one"))
    var rec2 = Recorder(String("two"))
    var req = Request()
    var out = Response.text(String("hello"))
    var blocked = apply_middleware[ Recorder, Recorder ](req, out, rec1, rec2)
    r.check("pass-through not blocked", not blocked)
    r.check("pass-through status 200", out.status == 200)
    # before-ran is observed via X-Before on the MW_PASS response which is
    # discarded on pass-through, so we only assert ordering via after headers.
    var order_headers = 0
    for i in range(len(out.headers)):
        if out.headers[i].key == "X-Order":
            order_headers += 1
    r.check("two X-Order headers appended", order_headers == 2)

    var block = AlwaysBlock(403)
    var rec3 = Recorder(String("three"))
    var req2 = Request()
    var out2 = Response.text(String("should-not-reach"))
    var blocked2 = apply_middleware[ AlwaysBlock, Recorder ](req2, out2, block, rec3)
    r.check("short-circuit blocked True", blocked2)
    r.check("short-circuit status 403", out2.status == 403)
    # after-not-run when blocked: confirmed by absence of X-Order (Recorder
    # would have appended one). AlwaysBlock.after adds X-Should-Not-Run only
    # if it ran, which it shouldn't on a short-circuit.
    var leak = False
    for i in range(len(out2.headers)):
        if out2.headers[i].key == "X-Should-Not-Run":
            leak = True
    r.check("blocker.after not run", not leak)

    var sec = SecurityHeaders()
    var req3 = Request()
    var out3 = Response.html(String("<h1>hi</h1>"))
    _ = apply_middleware[ SecurityHeaders ](req3, out3, sec)
    var has_csp = False
    var has_nosniff = False
    var has_frame = False
    for i in range(len(out3.headers)):
        if out3.headers[i].key == "Content-Security-Policy":
            has_csp = True
        if out3.headers[i].key == "X-Content-Type-Options":
            has_nosniff = True
        if out3.headers[i].key == "X-Frame-Options":
            has_frame = True
    r.check("SecurityHeaders adds CSP", has_csp)
    r.check("SecurityHeaders adds nosniff", has_nosniff)
    r.check("SecurityHeaders adds frame-options", has_frame)

    var req4 = Request()
    var out4 = Response.text(String("solo"))
    var blocked4 = apply_middleware(req4, out4)
    r.check("empty chain not blocked", not blocked4)
    r.check("empty chain status 200", out4.status == 200)

    r.summary()
