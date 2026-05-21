"""baldr — a general-purpose Mojo package for HTTP-fronted applications.

Apache-2.0. This package is a general-purpose web-application
substrate; it does not implement or describe any separately-maintained
proprietary technology of Light of Baldr LLC.

Public API as of Phase 5:

  from baldr.app        import App, DispatchHandler
  from baldr.request    import Request
  from baldr.response   import Response, Header
  from baldr.templates  import Templates
  from baldr.template   import Value
  from baldr.json       import JsonValue, parse, dumps
  from baldr.env        import env_str, env_int, env_bool
  from baldr.queue.cpu  import CpuQueue, Match
  from baldr.middleware.security_headers import apply_security_headers
  from baldr.middleware.ratelimit        import RateLimit, make_429
  from baldr.middleware.logger           import log_request

Phase roadmap:

  Phase 0 — scaffolding                  ✓
  Phase 1 — vendored primitives          ✓
  Phase 2 — public API layer             ✓
  Phase 3 — CPU/SIMD storage backend     ✓
  Phase 4 — middleware                   ✓
  Phase 5 — examples                     ✓
  Phase 6 — docs + benchmarks            ← current

See `docs/DESIGN.md` for the design tradeoffs and Mojo 1.0 quirks.
"""
