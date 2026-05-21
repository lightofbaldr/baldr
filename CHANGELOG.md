# baldr — changelog

All versions are `0.1.0-alpha.*` until the v0.1 release.
Newest entries first.

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
