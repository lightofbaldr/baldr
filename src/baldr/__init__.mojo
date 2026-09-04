"""baldr — a general-purpose Mojo package for HTTP-fronted applications.

Apache-2.0. This package is a general-purpose web-application
substrate; it does not implement or describe any separately-maintained
proprietary technology of Light of Baldr LLC.

Public API as of Phase 5:

  from baldr.app        import App, DispatchHandler, RouteHandler
  from baldr.request    import Request
  from baldr.response   import Response, Header
  from baldr.router     import Params, Router, RoutePattern, Match
  from baldr.cookies    import Cookie, SetCookie, parse_cookies
  from baldr.validation import Required, StringLength, FieldType, validate_json
  from baldr.assets     import AssetManifest, AssetRecord, build_assets, content_hash, manifest_to_context
  from baldr.config     import ServerConfig
  from baldr.errors     import ErrorHandler, DefaultErrorHandler, JsonErrorHandler, HtmlErrorHandler
  from baldr.testing    import TestClient, RouteTestClient, get, post, post_json, put, delete
  from baldr.lifecycle   import LifecycleHooks, NoLifecycle
  from baldr.concurrency import run_concurrent
  from baldr.templates  import Templates
  from baldr.template   import Value
  from baldr.json       import JsonValue, parse, dumps
  from baldr.env        import env_str, env_int, env_bool
  from baldr.db         import Db, Row
  from baldr.queue.cpu  import CpuQueue, Match
from baldr.middleware.security_headers import apply_security_headers
from baldr.middleware.ratelimit        import RateLimit, make_429
from baldr.middleware.logger           import log_request
from baldr.middleware.chain             import Middleware, Chain, NoMiddleware, SecurityHeaders, RequestLogger, RateLimitMW, apply_middleware

Phase roadmap:

  Phase 0 — scaffolding                  ✓
  Phase 1 — vendored primitives          ✓
  Phase 2 — public API layer             ✓
  Phase 3 — CPU/SIMD storage backend     ✓
  Phase 4 — middleware                   ✓
  Phase 5 — examples                     ✓
  Phase 6 — docs + benchmarks            ✓
  Phase 2.1 — routing + params           ✓
  Phase 2.2 — middleware chain            ✓
  Phase 2.3 — request/response (cookies/SSE) ✓
  Phase 2.4 — validation + JSON binding   ✓
  Phase 2.5 — templating v2 (loop var, filters, includes) ✓ (extends/blocks: planned)
  Phase 2.6 — JS/CSS asset pipeline             ✓
  Phase 2.7 — error handling + typed Config     ✓
  Phase 2.8 — TestClient + lifecycle            ✓
  Phase 2.9 — concurrency (prefork)             ✓

See `docs/DESIGN.md` for the design tradeoffs and Mojo 1.0 quirks.
"""
