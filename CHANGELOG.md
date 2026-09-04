# baldr — changelog

All versions are `0.1.0-alpha.*` until the v0.1 release.
Newest entries first.

## One `run`: the App carries its parts (2026-09-04)

- **Prefork supervision and graceful shutdown.** `run(..., workers=N,
  grace_secs=5)` catches SIGTERM/SIGINT process-wide with a minimal handler
  that writes to a per-process self-pipe; App logic polls outside signal
  context. Workers drain their active connection;
  the parent reaps and respawns unexpected exits with backoff, gives up after
  five respawns inside 10 seconds, and SIGKILLs only workers that outlive the
  grace deadline. Single-process mode follows the same drain contract.

- **Keep-alive and streaming in the accept loop.** Every `run` now serves a
  connection as a loop: HTTP/1.1 keeps it open by default (HTTP/1.0 opts in
  with `Connection: keep-alive`), pipelined requests are served in order,
  the response carries the `Connection:` header the loop decided on, and an
  idle kept-alive client is bounded by `KEEPALIVE_IDLE_SECS` (2 s). New
  `StreamHandler` trait — `__call__(mut self, req, mut out: ResponseStream)`
  — for chunked / Server-Sent-Event responses through `app.run` and
  `workers=N`; mounts and middleware `before` still apply, `after` hooks do
  not. `App.serve_connection(fd, handler)` exposes the per-connection loop
  (tests drive it over `socket_pair()`); `examples/sse` streams ticks to an
  `EventSource`. `Response.to_bytes(keep_alive)`; `read_request_from`
  keeps a per-connection buffer; `socket_shutdown_write` for tests. New
  suite `tests/test_app_keepalive.mojo` (20 checks). Roadmap items 2 and 3
  close.

- **`workers=N` on `run`.** Prefork moved into the App: the parent runs
  `on_startup`, binds, forks `N` workers that share the socket, and each
  worker runs the full pipeline it inherited (mounts, middleware, routes,
  error handler). No `Copyable` bound. `run_concurrent` stays as a
  deprecated wrapper; `fork`/`wait`/`getpid` live in `baldr.http` as
  `process_*`. Punch-list P0 #5 closes; supervision and keep-alive remain.

- **`App[M: Middleware = NoMiddleware, E: ErrorHandler = DefaultErrorHandler,
  L: LifecycleHooks = NoLifecycle]`.** Middleware, the error handler and the
  lifecycle hooks are type parameters with defaults, inferred from the
  constructor: `App()`, `App(errors=JsonErrorHandler())`,
  `App(middleware=Chain((SecurityHeaders(), RequestLogger())), errors=...,
  lifecycle=...)`. Keyword-only overloads cover every combination.
- **One `run`**, overloaded on the handler trait: a `RouteHandler` gets the
  route table resolved (405 + `Allow` / 404), a `DispatchHandler` routes by
  hand. Per request: static → assets → `before` → routes → handler → `after`
  → error handler. `App.handle(handler, req)` runs the same pipeline on one
  in-memory request for tests (new suite `tests/test_app_pipeline.mojo`, 39
  checks).
- **Stateful middleware.** `Middleware.before/after` take `mut self`; stages
  are App fields (a `Chain[*Ms]` holds them in a `Tuple`). `RequestLogger`
  logs elapsed milliseconds; new `RateLimitMW(cooldown_s, what)` is a chain
  stage keyed on `req.peer`. `NoMiddleware`, `DefaultErrorHandler`,
  `NoLifecycle` are the defaults; `JsonErrorHandler` / `HtmlErrorHandler`
  are `Defaultable`, so `App[E=JsonErrorHandler]()` works.
- **Deprecated, still working:** `run_routes`, `run_middleware`,
  `run_routes_middleware`, `run_routes_middleware_eh`, `run_full` — each is
  `run` with the parts as arguments. Removed at v0.2. One behaviour change:
  an unparseable request now goes through the error handler
  (`render_error(400, ...)`), so with `JsonErrorHandler` a bad request is JSON
  rather than the old plain-text `400 bad request`.
- `apply_middleware` takes its stages by value (`var *mws`); `App` is no
  longer `Copyable`.
- Punch-list P0 #2 and #4 close. Per-route *function* binding still waits on
  storable function pointers.

## Mojo 1.0.0 stable, the GPU split, and the public tree catches up (2026-09-04)

- **Toolchain:** `mojo==1.0.0` / `max==26.5.0` from the `conda.modular.com/max`
  release channel (was the dev2026070123 / dev2026080106 nightlies). Every
  suite, example and bench builds with **zero warnings**; **451 / 451 across
  24 suites**.
- **Port to 1.0.0 stable** (on top of the August nightly port): the three
  examples convert `perf_counter_ns()` to `UInt` at the logger boundary;
  `ImplicitlyDeletable` → `Deinitable`; `__del__` → `__deinit__`;
  `UnsafePointer` → `Pointer`; `bitcast` → `unsafe_bitcast`; `ptr + n` →
  `unsafe_offset`; `load` → `unsafe_load`.
- **The `test_queue_api` hang, open since the August port, diagnosed and fixed
  where the code now lives (`mojo-gpuq`):** Mojo destroys struct fields in
  declaration order; `GpuQueue` declared its `DeviceContext` before the
  `DeviceBuffer` it owned, so the next context in the same process
  deadlocked in the driver. Buffer declared first + explicit `__deinit__`.
- **GPU split applied to the public tree:** `baldr.queue.gpu` / `gpu_store`
  and their tests moved out to `mojo-gpuq` (Adam's 2026-08-03 call); the
  `Queue` facade stays as the seam for an out-of-process client. baldr has no
  CUDA surface.
- **Public repo = the full line:** routing (`baldr.router`, name-dispatch),
  cookies, validation, `TestClient` + lifecycle hooks, typed `ServerConfig`,
  error handlers, prefork concurrency, the JS/CSS asset pipeline, template
  includes + v2 filters, the 2026-06-18 security hardening, the docs site
  (`mkdocs.yml`, `docs/`) and the four extra examples — previously only on
  the internal line — now ship here.
- **DX:** every compile task creates `build/` first, so a fresh clone can run
  `pixi run test`.

## Nightly migration — Mojo dev2026070123 (linear types + AnyOrigin)

- Migrated to the 2026-07 nightly, which landed the **linear-types trait
  overhaul** (`ImplicitlyDestructible` → `ImplicitlyDeletable`; `List`/`Dict`/…
  now conform only when their element does). Recursive structs (`JsonValue`,
  template `Value`/`Node`) hit an unresolvable `List[Self]`↔`Self` conformance
  cycle → anchored each with an explicit `def __del__(deinit self)` +
  `ImplicitlyDeletable` conformance.
- `GpuQueue`: struct fields may no longer expose `AnyOrigin`, so the cached
  `dev_base: UnsafePointer[UInt8, MutAnyOrigin]` field was removed; the device
  base pointer is now derived on demand from `dev_buf` via `_base()`.
- Also: `fn` is removed on this nightly (use `def`, even for `__del__`).
- pinned `mojo==1.0.0b3.dev2026070123` / `max==26.5.0.dev2026070123`.
- Full suite green on the new nightly, including the GPU queue.

## Phase 2.9 — concurrency (prefork)

- New `baldr.concurrency`: `run_concurrent[H: DispatchHandler & Copyable]` —
  a prefork worker pool (the classic nginx/Apache model): parent binds+
  listens, forks N workers, each worker `accept()`s on the shared socket
  with its own `handler.copy()` and runs a serial accept loop.
- Why prefork not pthreads: Mojo 1.0 has no `std.threading`, and the `mut self`
  handler model can't share safely across threads. Prefork gives each worker
  its own copy -> NO shared mutable state, NO mutex. Stateless handlers
  parallelize trivially; stateful handlers move shared state into `baldr.queue`
  or an external store. Uses `fork`/`wait`/`getpid` via libc FFI.
- New `examples/concurrency` (live-verified: 4 parallel 1s requests finish
  in ~1.0s vs ~4s serial, served by 4 distinct worker PIDs) and
  `tests/test_concurrency.mojo` (9 tests: fork/wait/getpid + handler copy
  independence). Suite: 428/428 (was 419/419).
- Deferred: real SIGTERM/SIGINT FFI for graceful worker shutdown; thread-pool
  variant if Mojo adds stable threads + trait objects.

## Phase 2.8 — TestClient + lifecycle hooks

- New `baldr.testing`: `TestClient[H: DispatchHandler]` and
  `RouteTestClient[H: RouteHandler]` drive a handler in-process (no sockets);
  request builders `get/post/post_json/put/delete/with_header`. RouteTestClient
  resolves the router first so 405/404 mirror the live server.
- New `baldr.lifecycle`: `LifecycleHooks` trait (`on_startup`/`on_shutdown`).
- New `App.run_full[H, *Ms, E, L]`: the capstone runner combining routes +
  middleware + error handler + lifecycle (on_startup before bind,
  on_shutdown in a finally). Real SIGTERM/SIGINT FFI deferred.
- New `tests/test_testing_lifecycle.mojo` (22 tests). Suite: 419/419.

## Phase 2.7 — error handling + typed Config

- New `baldr.config`: `ServerConfig.from_env()` assembles host/port/debug/
  workers/max_body_bytes/static_dir/template_dir from env + `.env` + defaults.
- New `baldr.errors`: `ErrorHandler` trait + `JsonErrorHandler` (API apps ->
  `{"error","message","status"}` JSON) and `HtmlErrorHandler` (browser apps,
  HTML-escapes the message). `_status_label` maps codes to snake_case labels.
- New `App.run_routes_middleware_eh[H, *Ms, E: ErrorHandler]`: full-stack
  runner (routes + middleware + asset/static mounts) that renders any accept-
  loop exception via `eh.render_error(500, msg, req)` instead of the plain-
  text fallback. Plain `run*` methods keep their inline 500 behavior.
- New `tests/test_config_errors.mojo` (19 tests). Suite: 397/397 (was 378/378).

## Phase 2.6 — JS/CSS asset pipeline

- New `baldr.assets` module: `AssetRecord`/`AssetManifest` (logical-name ->
  hashed-URL, with `url_for`, `has`, `content_type_for`, `find_by_url`),
  `content_hash` (pure-Mojo FNV-1a 64-bit, 16 hex — stdlib has no `std.hash`),
  `bundle_js`/`bundle_css` (concat + conservative minify: strip // and /* */
  comments, collapse whitespace), `build_assets` (walk a source dir, bundle
  JS/CSS, pass through binary assets, hash, write hashed outputs), and
  `manifest_to_context` (template integration via an `assets` dict).
- `App.assets(manifest, url_prefix)`: asset-aware static mount serving hashed
  URLs with `Cache-Control: public, max-age=31536000, immutable` + `ETag`,
  honoring `If-None-Match` for cheap 304s. Consulted after `static()` mounts,
  before routes/handler.
- **Deferred:** SRI sha256 (needs a hash impl), `|asset` template filter
  (needs a filter registry the v0.1 evaluator lacks — use `{{ assets["x.js"] }}`
  via `manifest_to_context` instead), TypeScript/SCSS transpilation (external
  tool, v0.3), dev hot-reload livereload poller.
- New `tests/test_assets.mojo` (27 tests). Suite: 378/378 (was 351/351).

## Phase 2.5 — templating v2 (loop variable, filters, includes)

- `{% for %}` now exposes a Jinja-style `loop` dict on the render context:
  `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last`,
  `loop.length`, `loop.revindex`, `loop.revindex0`.
- New built-in filters: `capitalize`, `trim`, `abs`, `join(sep?)`,
  `truncate(n)` (appends `...` when truncated). Existing filters unchanged.
- `{% include "name" %}` — template inheritance/includes. A new
  `TemplateLoader` trait + `NoLoader` default; `render(t, ctx)` stays
  backward-compatible (raises on include), `render_with_loader[L](t, ctx, loader)`
  resolves partials at render time. The filesystem `Templates` wrapper now
  conforms to `TemplateLoader`, so includes resolve against its directory.
  Partials see the current context; includes can nest and work inside for-loops.
- New `tests/test_template_v2.mojo` (19) + `tests/test_template_include.mojo`
  (7). Suite: 351/351 (was 344/344).
- **Still deferred:** `{% extends %}`/`{% block %}` (block-override resolution
  needs a multi-pass compile; future work).

## Phase 2.4 — validation + JSON binding

- New `baldr.validation` module: `FieldError`, `ValidationResult` (with
  `to_response()` -> 422 JSON `{"ok":false,"errors":[...]}`), `Validator`
  trait (non-mut `self` so it composes through the comptime runner),
  `validate_json[*Vs]` runner, and built-in `Required`, `StringLength`,
  `FieldType` validators.
- `Request.validate[*Vs]` parses the body as JSON and runs a comptime chain
  of validators; usage:
      var r = req.validate(Required("name"), StringLength("name",1,100))
      if not r.ok: return r.to_response()
- New `tests/test_validation.mojo` (25 tests). Suite: 325/325 (was 300/300).

## Phase 2.3 — request/response enrichment (cookies + SSE)

- New `baldr.cookies` module: `Cookie`, `SetCookie` (builder with
  `with_path/domain/expires/max_age`, `with_http_only`, `with_secure`,
  `same_site_*`), `parse_cookies(header)`.
- `Request.cookies()` / `Request.cookie(name, default)` parse the `Cookie`
  request header.
- `Response.with_cookie` (chainable, returns new) / `add_cookie` (mutating)
  append `Set-Cookie` headers (multiple, order-preserving).
- `Response.sse(events)` builds a `text/event-stream` response with
  spec-correct `data:` framing. (baldr's `Connection: close` model sends
  the finite feed at once; long-lived streaming needs transport changes.)
- New `tests/test_cookies.mojo` (23 tests). Suite: 306/306 (was 283/283).

## Phase 2.2 — middleware chain

- New `baldr.middleware.chain` module: `Middleware` trait (`before(req) ->
  Response` with `status == MW_PASS` sentinel to continue, `after(req, mut
  resp)` to mutate in place), `apply_middleware[*Ms]` runner (comptime-
  monomorphized over concrete middleware types — zero per-request vtable, no
  storable-fn-pointer dependency), and built-in conformers `SecurityHeaders`
  and `RequestLogger` wrapping the v0.1 free functions.
- New `App.run_middleware[H: DispatchHandler, *Ms: Middleware]`: accept loop
  that runs the `before` chain (short-circuit on non-MW_PASS), the handler,
  then the `after` chain over the response. Static mounts still win.
- `Response.add_header` (mutating in-place variant) added for `after` hooks.
  `apply_security_headers` now takes the response by read borrow.
- **Mojo 1.0 constraint documented:** stateful middleware (e.g. a rate
  limiter persisting per-key hits across requests) needs `mut self`, which the
  variadic chain dispatch (on rvalues) forbids. Such middleware stays
  hand-woven in the handler (v0.1 pattern) where the handler owns the state
  via its own `mut self`. See `chain.mojo` notes. A `RateLimitMW` chain
  conformer is intentionally NOT provided for this reason.
- New `examples/middleware/main.mojo` and `tests/test_middleware_chain.mojo`
  (11 tests). Suite: 283/283 (was 272/272).

## Phase 2.1 — routing + params

- New `baldr.router` module: `Params` (path-param bag with `get`/`get_int`/
  `has`/`is_empty`/`len`), `RoutePattern` (parses `/users/{id}/posts/{pid}`
  into literal/param segments, slash-insensitive match), `Router` (registers
  method+pattern+name; `resolve` returns a `Match` with `ROUTE_OK` /
  `ROUTE_METHOD_NOT_ALLOWED` (with `Allow` list) / `ROUTE_NOT_FOUND`), and
  convenience `get/post/put/delete/patch/head` registrars.
- New `RouteHandler` trait in `baldr.app`: `__call__(mut self, req, params)`.
- New `App.run_routes[H: RouteHandler]`: accept loop that resolves the route
  table first (static mounts still win), calls the handler with extracted
  params on a match, returns 405+`Allow` on a method mismatch, 404 on no
  match. `App.route/get/post/put/delete/patch/head` register routes.
- Non-breaking: `DispatchHandler` + `App.run[H]` unchanged.
- New `examples/route/main.mojo` and `tests/test_router.mojo` (30 tests).
- Suite: 272/272 (was 242/242).

## Post-Phase-6 (2026-05-18)

- Queue / CpuQueue / GpuQueue: `capacity()`, `tail()`, `queue_bytes()`,
  `kv_count()` accessors so metrics endpoints can read buffer state
  without poking private fields. Used by `mojo-stack-demo-v2`'s
  `/api/stats` dashboard.
- Examples: drop `Copyable` from `DispatchHandler` conformance — the
  GPU backend owns unique CUDA resources so the trait is `Movable`-only.
  The three bundled examples (`hello`, `chat`, `scan`) match.
- **`GpuQueue` extraction** (closes Task #217): in-process GPU-backed
  store extracted from the vendored TCP-server `gpu.mojo`. Same method
  surface as `CpuQueue`. `Queue.local()`'s `auto`/`gpu` branches now
  actually return GPU-backed storage when libcuda is available. Verified
  on Spark 2's GB10. Test suite **242 / 242**.
- **`baldr.queue.Queue` facade**: env-driven CPU/GPU selection via
  `BALDR_QUEUE_BACKEND ∈ {cpu, auto, gpu}`. Public method surface
  matches `CpuQueue` 1:1.
- **`baldr.env.load_dotenv`**: read `.env` files into the process
  environment, real env wins over file entries.
- **`baldr.env`**: typed env-var helpers — `env_str`, `env_int`,
  `env_bool`.

## Phase 6 — docs + benchmarks (`fdcb0b5`)

- `README.md` rewritten with the actual v0.1 API (trait dispatch,
  env-driven backend, pixi commands).
- `docs/PERF.md` — measured numbers on Spark 2 ARM Neon. CPU substring
  scan stable at **1.0–1.1 GB/s** from 1 MB to 256 MB corpora; queue
  push/pop **5.0M / 9.7M ops/s** on 60 B payloads; KV set/get
  **4.0M / 5.6M ops/s**; HTTP handler ~7 µs.
- `docs/DESIGN.md` — contributor guide: layer map, trait-dispatch
  history, CPU/GPU record-shape symmetry, SIMD-scan two-stage pattern,
  append-only memory model, Mojo 1.0 syntax quirks.
- `bench/bench_cpu.mojo` + `pixi run bench-cpu` reproduce all the
  PERF.md numbers.

## Phase 5 — examples + trait dispatch (`743f034`)

- `App.run` refactor: replaced the comptime-dispatch pattern with a
  `DispatchHandler` trait (`def __call__(mut self, req) raises ->
  Response`). Handlers carry their own state (rate limiters, queues,
  templates) between requests via `mut self`. Mojo 1.0's anonymous
  function-types don't accept named `def` functions; the trait
  resolves it.
- `examples/hello` (port 8090) — HTML + JSON + static + 404, curl-tested.
- `examples/chat` (port 8092) — Templates with auto-escape; XSS probe
  `<script>` → `&lt;script&gt;`.
- `examples/scan` (port 8091) — `CpuQueue.find_str` over 8 MB / 64 MB
  synthetic corpora. Measured **~1.4 GB/s** scan on Spark 2 ARM Neon.

## Phase 4 — middleware (`0174bea`)

- `baldr.middleware.security_headers.apply_security_headers(resp,
  csp=?)` — chains five hardening headers, default CSP overridable.
- `baldr.middleware.ratelimit.RateLimit` — per-key cooldown tracker,
  deterministic (caller passes `now_s`). `make_429(retry_after, what)`
  builds the standard 429 shape. `now_epoch_s()` convenience.
- `baldr.middleware.logger.format_log_line` / `log_request` —
  microsecond-precision request log.
- 30 assertions in `tests/test_middleware.mojo`.

## Phase 3 — CPU / SIMD storage backend (`4e410ec`)

- `baldr.queue.cpu.CpuQueue` — ring-buffer + KV `Dict` + task table.
  Queue / KV / Tasks share an append-only data buffer.
- SIMD substring scan via `SIMD[DType.uint8, 32]` two-stage pattern:
  broadcast `needle[0]`, compare, scalar verify on hits, scalar tail.
  Runs on Spark 2 ARM Neon today, compiles to AVX2 on x86.
- 33 assertions in `tests/test_queue_cpu.mojo`.

## Phase 2 — public API layer (`3680a39`)

- `baldr.request.Request` — method, path, query, body, headers; `form()`
  and `json()` accessors; `parse_request(raw_bytes) -> Request`.
- `baldr.response.Response` + `Header` — static ctors
  `text/html/json/redirect/file`, `with_header()` chain, full HTTP/1.1
  `to_bytes()`.
- `baldr.templates.Templates(dir)` — filesystem wrapper around
  `template.Template` with lazy compile + optional `reload=True`.
- `baldr.app.App` + (initial) comptime dispatcher — see Phase 5 for the
  trait-based refactor.
- 29 assertions in `tests/test_api.mojo`.

## Phase 1 — vendor source repos under namespace (`d673be1`)

- Pull `mojo-http` / `mojo-serve` / `mojo-template` / `mojo-json` /
  `mojo-gpuq` plus the gpuq TCP client into `src/baldr/{http, serve,
  template, json, queue/{gpu, client}}`.
- `def main()` renamed to `_demo()` in `http.mojo`, `serve.mojo`,
  `queue/gpu.mojo` so they parse as library modules.
- Fixed one pre-existing lvalue typecheck error in `queue/client.mojo`'s
  `gpuq_claim`.
- `tests/test_imports.mojo` (6 assertions) + 36 template + 43 json
  vendored tests = **85 / 85**.

## Phase 0 — scaffolding (`c857141`)

- `SPEC.md`, `README.md`, `LICENSE`, `pixi.toml`,
  `src/baldr/__init__.mojo`.
- Sanitation gate established: every commit passes a banned-vocabulary
  sweep before push.
