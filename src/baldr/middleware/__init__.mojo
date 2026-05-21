"""baldr.middleware — opt-in pre/post-processing helpers.

Phase 4 ships stateless helpers + the `RateLimit` struct. Users weave
them into their request dispatcher manually (because Mojo 1.0 doesn't
yet support storing a chain of `def`-typed handlers in a list — see
`baldr.app` for the same constraint on per-route registration).

Typical pattern:

    var limiter = RateLimit()

    def dispatch(req: Request) raises -> Response:
        var t0 = perf_counter_ns()

        var retry = limiter.check(req.path, cooldown_s=5)
        if retry > 0:
            var r = make_429(retry, req.path)
            log_request(req, r, t0)
            return r

        var resp = real_handler(req)
        resp = apply_security_headers(resp)
        log_request(req, resp, t0)
        return resp

Public surface lands incrementally as each helper is written.
"""
