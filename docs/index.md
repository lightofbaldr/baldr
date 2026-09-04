---
hide:
  - toc
---

<div class="kf-hero" markdown>

<svg class="kf-flame" viewBox="0 0 32 32" aria-hidden="true"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#FF7A1A"/><stop offset="55%" stop-color="#FF3B7C"/><stop offset="100%" stop-color="#A656FF"/></linearGradient></defs><path fill="url(#g)" d="M16 2c0 6-7 7-7 14a7 7 0 0 0 14 0c0-3-2-5-3-7 0 3-2 4-2 7a3 3 0 1 1-6 0c0-5 6-7 4-14z"/></svg>

<div class="kf-title">The <span class="kf-grad">FastAPI of Mojo</span></div>

<p class="kf-sub">A batteries-included web framework in pure Mojo. One import surface, one static binary out — and <strong>no Python on the request path</strong>.</p>

<div class="kf-cta">
  <a class="kf-btn kf-btn-primary" href="get-started/">Get started →</a>
  <a class="kf-btn kf-btn-ghost" href="tutorial/first-steps/">First steps</a>
</div>

<p class="kf-meta">pre-alpha · Apache-2.0 · runs on aarch64 & x86 · GPU via MAX, not CUDA</p>

</div>

<div class="kf-stats">
  <div class="kf-stat"><div class="n">428</div><div class="l">tests green</div></div>
  <div class="kf-stat"><div class="n">1</div><div class="l">static binary</div></div>
  <div class="kf-stat"><div class="n">0</div><div class="l">python on request</div></div>
  <div class="kf-stat"><div class="n">~7µs</div><div class="l">handler time</div></div>
</div>

## A whole web app, in one file

No decorators-over-an-interpreter. A baldr handler is a **struct that owns its state** between requests, and the whole thing compiles to a single native binary:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    var greeting: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.method == "GET" and req.path == "/":
            return Response.html("<h1>" + self.greeting + "</h1>")
        return Response.text("404\n", 404)

def main() raises:
    var app = App()
    app.run(HelloApp("hello, baldr"), port=8080)
```

```console
$ pixi run mojo build main.mojo -o app && ./app
[baldr] listening on 0.0.0.0 port 8080
```

That binary is the *entire* server: real HTTP/1.1, HTML with auto-escape, JSON in and out, static files, middleware — no runtime, no interpreter, nothing to `pip install` on the box.

## What's in the box

<div class="kf-cards" markdown>

<div class="kf-card" markdown>
<div class="g">📦</div>
### One static binary
Compiles to a single native executable. Ship it in a `FROM scratch` image a few MB in size. No Python on the request path, ever.
</div>

<div class="kf-card" markdown>
<div class="g">🧩</div>
### Batteries included
Routing with path params, Request/Response, a Jinja-shaped template engine, RFC-8259 JSON, middleware, a GPU-resident queue, a `TestClient`.
</div>

<div class="kf-card" markdown>
<div class="g">🔩</div>
### Traits, not magic
Handlers conform to `DispatchHandler` and **own their state** — rate limiters, caches, queues live in the struct between requests. Comptime-monomorphized, no per-request vtable.
</div>

<div class="kf-card" markdown>
<div class="g">🌀</div>
### Portable & fast
One source vectorizes to AVX2 on x86 and Neon on ARM; GPU work runs through **MAX**, not hand-written CUDA. Write it once, run it fast on your laptop *and* the DGX.
</div>

<div class="kf-card" markdown>
<div class="g">✅</div>
### Proven
428 assertions across nine suites, bit-equivalence oracles, and a prefork worker pool that actually parallelizes.
</div>

<div class="kf-card" markdown>
<div class="g">🚀</div>
### Deploy in one line
The binary + a static dir is the whole deploy. A ten-line `FROM scratch` Dockerfile and you're live.
</div>

</div>

<div class="kf-cta" style="margin-top:2rem">
  <a class="kf-btn kf-btn-primary" href="tutorial/first-steps/">Build your first app →</a>
</div>
