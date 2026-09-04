"""baldr.middleware.chain — comptime-monomorphized middleware pipeline.

Phase 2.2 — middleware. A `Middleware` trait with two hooks:

  - `before(req) -> Response`  — runs before the handler. Return a
    `Response` with `status == 0` (the sentinel "pass" value) to let the
    chain continue; return a real response (non-zero status) to
    short-circuit the whole pipeline (e.g. 429 rate-limit, 401 auth).
  - `after(req, mut resp)`     — runs after the handler, mutating the
    response in place (append headers, log, etc.). No return value.

`apply_middleware[*Ms](*mws, req, handler_fn)` runs the `before` hooks in
order, calls `handler_fn(req)` if none short-circuit, then runs the
`after` hooks in order over the response. The whole pipeline is
comptime-monomorphized over the concrete middleware types — zero
per-request vtable dispatch, and no storable-function-pointer dependency
(Mojo 1.0 doesn't guarantee those).

Why `before` returns a `Response` (not `Optional[Response]`): `Response`
holds `List` fields which are not `ImplicitlyCopyable`, so it cannot be
stored in `Optional`/`Tuple`. Returning a moved `Response` with a
sentinel `status == 0` is the idiomatic way to signal "no short-circuit"
without a copy.

Why `after` takes `mut resp` (inout) rather than returning a new
`Response`: an owned `Response` parameter anywhere in a variadic trait's
method set forces copy semantics on the trait dispatch, which `Response`
can't satisfy. Mutating in place sidesteps that.

Conformers wrap the existing free-function middleware
(`apply_security_headers`, `make_429`, `log_request`) so the v0.1
hand-woven pattern and the v0.2 chain pattern share one implementation.
"""

from std.time import perf_counter_ns

from ..request import Request
from ..response import Response
from .security_headers import apply_security_headers, DEFAULT_CSP
from .ratelimit import RateLimit, make_429, now_epoch_s


comptime MW_PASS = 0  # sentinel: before() returns status==MW_PASS to continue


trait Middleware(Movable, Deinitable):
    """A composable middleware stage.

    Conform a struct to this trait and hand it to `App(middleware=...)` —
    a single stage, or several composed with `Chain((a, b, c))`. Stateless
    conformers (security headers) are the common case; stateful ones (a
    rate limiter holding a Dict, a logger timing each request) keep their
    state in fields — both hooks take `mut self` since Mojo 1.0.0, because
    the `App` owns its middleware as a field and calls it as an lvalue.
    Conformers that don't need to mutate may still declare `self`.
    """
    def before(mut self, req: Request) raises -> Response:
        """Run before the handler. Return a Response with `status == 0`
        (MW_PASS) to continue; return a real response to short-circuit the
        pipeline (the handler and every `after` hook are skipped)."""
        var r = Response()
        r.status = MW_PASS
        return r^

    def after(mut self, req: Request, mut resp: Response) raises:
        """Run after the handler, mutating `resp` in place. Default: no-op."""
        pass


# ── Composition ───────────────────────────────────────────────────────────
@fieldwise_init
struct NoMiddleware(Middleware, Defaultable, Copyable, Movable):
    """The empty pipeline: `App()`'s default middleware. Passes every request
    straight through and leaves every response alone."""
    var _unused: Int

    def __init__(out self):
        self._unused = 0


struct Chain[*Ms: Middleware](Middleware, Movable, Deinitable):
    """Several middleware stages as one `Middleware`.

    `before` hooks run in order and the first non-`MW_PASS` response wins
    (later stages, the handler and all `after` hooks are skipped); `after`
    hooks run in order over the handler's response. The pipeline is
    monomorphized over the concrete stage types — no per-request vtable
    dispatch — and each stage is an lvalue field, so stages may mutate
    themselves. Chains nest: a `Chain` is itself a `Middleware`.

        App(middleware=Chain((SecurityHeaders(), RequestLogger())))
    """
    var stages: Tuple[*Self.Ms]

    def __init__(out self, var stages: Tuple[*Self.Ms]):
        self.stages = stages^

    def before(mut self, req: Request) raises -> Response:
        comptime for i in range(len(Self.Ms)):
            var pre = self.stages[i].before(req)
            if pre.status != MW_PASS:
                return pre^
        var r = Response()
        r.status = MW_PASS
        return r^

    def after(mut self, req: Request, mut resp: Response) raises:
        comptime for i in range(len(Self.Ms)):
            self.stages[i].after(req, resp)


# ── Built-in conformers (wrap the v0.1 free-function middleware) ──────────
@fieldwise_init
struct SecurityHeaders(Middleware, Copyable, Movable):
    """Apply the five standard hardening headers in `after`."""
    var csp: String

    def __init__(out self):
        self.csp = DEFAULT_CSP

    def after(self, req: Request, mut resp: Response) raises:
        var hardened = apply_security_headers(resp, self.csp)
        resp.status = hardened.status
        resp.body = hardened.body.copy()
        resp.headers = hardened.headers.copy()


@fieldwise_init
struct RequestLogger(Middleware, Copyable, Movable):
    """Log each request after it completes: method, path, status and the
    elapsed milliseconds. Stateful: `before` stamps the start time, `after`
    reads it — the `mut self` hooks make that possible."""
    var start_ns: UInt

    def __init__(out self):
        self.start_ns = UInt(0)

    def before(mut self, req: Request) raises -> Response:
        self.start_ns = UInt(perf_counter_ns())
        var r = Response()
        r.status = MW_PASS
        return r^

    def after(mut self, req: Request, mut resp: Response) raises:
        var elapsed_ms = (UInt(perf_counter_ns()) - self.start_ns) // UInt(1_000_000)
        print(req.method, req.path, String("->"), String(resp.status), String(elapsed_ms) + "ms")


@fieldwise_init
struct RateLimitMW(Middleware, Movable):
    """Per-client cooldown as a middleware stage.

    Keys on `req.peer` (the kernel-reported client IP; requests with an
    unknown peer share one key). A client inside its cooldown gets the
    standard `make_429` response — `Retry-After` set — before the handler
    runs. Holds the `RateLimit` table across requests: the stateful case
    the old variadic chain could not express."""
    var limiter: RateLimit
    var cooldown_s: Int
    var what: String

    def __init__(out self, cooldown_s: Int, what: String = String("requests")):
        self.limiter = RateLimit()
        self.cooldown_s = cooldown_s
        self.what = what

    def before(mut self, req: Request) raises -> Response:
        var key = req.peer if req.peer.byte_length() > 0 else String("<unknown>")
        var retry = self.limiter.check(key, self.cooldown_s, now_epoch_s())
        if retry > 0:
            return make_429(retry, self.what)
        var r = Response()
        r.status = MW_PASS
        return r^


# ── The pipeline runner ───────────────────────────────────────────────────
def apply_middleware[*Ms: Middleware](
    req: Request,
    mut resp: Response,
    var *mws: *Ms,
) raises -> Bool:
    """Run `before` hooks (short-circuit on non-zero status), then `after`
    hooks over `resp` in place.

    Returns True if a `before` hook short-circuited (in which case `resp`
    has been overwritten with the short-circuit response); False if the
    chain passed and only `after` hooks ran (mutating `resp` in place).

    The caller invokes the handler BEFORE calling this and passes the
    handler's response as `resp` - the handler is a separate trait object
    that can't be threaded through the variadic middleware types.
    """
    # before phase
    comptime for i in range(len(Ms)):
        var pre = mws[i].before(req)
        if pre.status != MW_PASS:
            resp.status = pre.status
            resp.body = pre.body.copy()
            resp.headers = pre.headers.copy()
            return True
    # after phase - mutate resp in place
    comptime for j in range(len(Ms)):
        mws[j].after(req, resp)
    return False
