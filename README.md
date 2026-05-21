# baldr

A general-purpose, batteries-included Mojo package for building
HTTP-fronted applications end-to-end in pure Mojo. One install, one
import surface, one binary out.

> **Status: pre-alpha** (v0.1.0-alpha.0). Phases 0–5 complete; Phase 6
> (docs + benchmarks) in progress. v0.1 release once Phase 6 lands.

## Quick start

```mojo
from baldr.app      import App, DispatchHandler
from baldr.request  import Request
from baldr.response import Response
from baldr.middleware.security_headers import apply_security_headers


@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    var greeting: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.method == "GET" and req.path == "/":
            return apply_security_headers(
                Response.html(String("<h1>") + self.greeting + "</h1>")
            )
        return Response.text(String("404\n"), 404)


def main() raises:
    var app = App()
    app.static(String("/static"), String("./public"))
    app.run(HelloApp(String("hello, baldr")), port=8080)
```

`pixi run example-hello && build/example-hello` → single static binary,
real HTTP/1.1, HTML templates with auto-escape, persistent state in
the dispatcher struct, JSON in and out. No Python on the request path.

The trait-based dispatcher pattern is load-bearing: handlers conform
to `DispatchHandler` with `def __call__(mut self, req) raises ->
Response`. The struct owns its state — rate limiters, queues, template
caches — between requests. See [`docs/DESIGN.md`](docs/DESIGN.md) for
why the v0.1 API ended up trait-based rather than function-pointer
based.

## What's in the bundle

| Layer | Module | Purpose |
|---|---|---|
| Sockets, HTTP/1.1 parser | `baldr.http` | raw POSIX sockets, request line + headers + body |
| Routing, static files, safe path joins | `baldr.serve` + `baldr.app` | URL → handler dispatch, `/static/` serving |
| HTML rendering, auto-escape | `baldr.template` + `baldr.templates` | Jinja2-shaped expressions, filters, file-system discovery |
| JSON in / out | `baldr.json` | RFC 8259 parser + emitter |
| Persistent state | `baldr.queue.cpu` + `baldr.queue.gpu` | Queue + KV + Tasks, SIMD substring scan, GPU-resident fallback |
| GPU memory cap shim (optional) | `mojo-cudart-shim` (separate repo) | LD_PRELOAD interposer for unified-memory hosts |
| Middleware | `baldr.middleware.*` | security_headers, ratelimit, logger |

## Examples

```bash
pixi run examples      # build all three under build/
build/example-hello    # :8090 — HTML + JSON + static + 404
build/example-chat     # :8092 — Templates + auto-escape XSS protection
build/example-scan     # :8091 — SIMD substring scan, ~1.4 GB/s on ARM Neon
```

Each is a single-file Mojo binary; total source under 250 lines.

## Build & test

```bash
pixi install                  # one-time
pixi run test                 # 177 / 177 assertions across 6 suites
pixi run examples             # all three binaries
```

Mojo `>= 1.0.0b1`, MAX `>= 26.2`. Tested on Spark 2 (DGX Spark, ARM64).
The same source compiles for `linux-aarch64` and `linux-64`.

## Phases

| Phase | Status | What |
|---|---|---|
| 0 | ✓ | Scaffolding + lint gate |
| 1 | ✓ | Vendor `mojo-http`/`mojo-serve`/`mojo-template`/`mojo-json`/`mojo-gpuq` under `baldr.*` |
| 2 | ✓ | Public API: `App`, `Request`, `Response`, `Templates` |
| 3 | ✓ | `CpuQueue` — CPU/SIMD backend with `find` substring scan |
| 4 | ✓ | Middleware: `security_headers`, `RateLimit`, `log_request` |
| 5 | ✓ | `examples/{hello,chat,scan}` — end-to-end curl-tested |
| 6 | ← | Docs + benchmarks (this work) |

## Docs

- [`docs/DESIGN.md`](docs/DESIGN.md) — contributor guide, design tradeoffs, Mojo 1.0 quirks.
- [`docs/PERF.md`](docs/PERF.md) — measured CPU/GPU/HTTP numbers on Spark 2.
- [`CHANGELOG.md`](CHANGELOG.md) — reverse-chrono record of every shipped change.

## License

[Apache-2.0](LICENSE).

## Notice

This repository is a general-purpose web-application substrate, released
under Apache-2.0. It does not implement or describe any
separately-maintained proprietary technology of Light of Baldr LLC.
