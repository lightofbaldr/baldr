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

from ..request import Request
from ..response import Response
from .security_headers import apply_security_headers, DEFAULT_CSP


comptime MW_PASS = 0  # sentinel: before() returns status==MW_PASS to continue


trait Middleware(Movable, Deinitable):
    """A composable middleware stage.

    Conform a `@fieldwise_init` struct (Copyable, Movable) to this trait
    and pass instances to `App.use[*Ms]` / `apply_middleware`. Stateless
    conformers (security headers, logging) are the common case; stateful
    ones (rate limiter holding a Dict) hold their own state via fields.
    """
    def before(self, req: Request) raises -> Response:
        """Run before the handler. Return a Response with `status == 0`
        (MW_PASS) to continue; return a real response to short-circuit.

        Non-mut so it composes through the variadic chain dispatch
        (mut-self on a variadic rvalue is not allowed in Mojo 1.0).
        Stateful middleware that needs per-request pre-state must carry it
        via the returned Response (e.g. an X-baldr-start header)."""
        var r = Response()
        r.status = MW_PASS
        return r^

    def after(self, req: Request, mut resp: Response) raises:
        """Run after the handler, mutating `resp` in place. Default: no-op."""
        pass


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
    """Log each request after it completes.

    Stateless across requests (the variadic chain forbids mut-self), so it
    cannot carry a per-request start timestamp through `before`/`after`.
    Instead it logs method, path, and status — the most useful fields for a
    single-binary deployment. Apps that need elapsed time can compute it in
    their handler and add an `X-baldr-elapsed` header this logger would pick
    up, or use the v0.1 free-function `log_request` directly with a captured
    start time."""
    var placeholder: Int  # kept so @fieldwise_init has a field

    def __init__(out self):
        self.placeholder = 0

    def after(self, req: Request, mut resp: Response) raises:
        print(req.method, req.path, String("->"), String(resp.status))


# NOTE: RateLimitMW is intentionally NOT provided as a variadic-chain
# conformer. A rate limiter must persist per-key hit times ACROSS requests,
# which requires `mut self` on the middleware instance — but the variadic
# chain dispatches on rvalues and cannot call mutating methods. Stateful
# middleware like this stays hand-woven inside the handler (the v0.1
# pattern) where the handler owns the `RateLimit` struct as a field and
# mutates it via its own `mut self` (an lvalue). See `examples/route` and
# the v0.1 `chat`/`scan` examples for the hand-woven pattern. A future
# Mojo release with storable fn pointers / trait objects would let a
# stateful RateLimitMW register through `App.use`.


# ── The pipeline runner ───────────────────────────────────────────────────
def apply_middleware[*Ms: Middleware](
    req: Request,
    mut resp: Response,
    *mws: *Ms,
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
