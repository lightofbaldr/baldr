# baldr — Developer-Experience Punch-List

*Generated 2026-07-02 while writing the docs site. Every gap below was surfaced by actually
documenting the framework against its real source — the docs are the gap-finder. 64 raw findings
across 18 pages, deduplicated and ranked here. File:line references are to `src/baldr/`.*

---

## ✅ Shipped 2026-07-02 (evening)

- **P0 #3 — `String("...")` verbosity → RESOLVED, by the language.** Compiling against the current
  nightly (`dev2026070123`) proved implicit `StringLiteral → String` is already live: a full baldr
  handler with **zero `String()` wraps** builds clean. This was never an API gap we had to close — the
  wraps are legacy from the older nightly the code was written against. Docs now teach bare literals
  (335 wraps stripped from doc samples); `String("...")` still compiles, so it's non-breaking.
- **P0 #1 — routing double-dispatch → RESOLVED.** `RouteHandler.__call__` now receives the matched
  route name: `__call__(mut self, req, params, name)`. Handlers dispatch with `if name == "note_show":`
  instead of re-branching on `req.path` — the route table is the single source of truth. Blast radius:
  the trait + 8 dispatch sites in `app.mojo`, 1 in `testing.mojo`, 2 handler impls; **460/460 tests
  green**. (Per-route *function* binding — the fuller fix — still waits on storable fn pointers.)

---

## ⭐ The one root cause behind half the P0 list

**Mojo 1.0 has no storable function pointers / trait objects.** You can't store a heterogeneous
callable or a `mut`-able trait value in a struct field. That single language gap directly forces:

- the **routing double-dispatch** — *name-threading shipped* (handler now gets the matched name); full per-route *fn* binding still blocked here,
- ~~the **six `run_*` methods**~~ ✅ shipped 2026-09-04: the parts are type parameters of `App` (`App(middleware=, errors=, lifecycle=)`), one `run`,
- ~~**stateless middleware**~~ ✅ shipped 2026-09-04: stages are App fields (lvalues), both hooks take `mut self`.

**Action:** watch the Modular changelog for storable fn pointers / callable trait objects. When it
lands, design the builder API + per-route binding + `mut self` middleware *together* — ~5 of the
biggest gaps close in one pass. Until then, the workarounds below are correct; document them loudly.

---

## P0 — Structural (these shape the public API; get them right before 1.0)

1. ~~**Routing makes you match twice.**~~ ✅ **SHIPPED (see above).** `Match.name` is now threaded into
   `RouteHandler.__call__(mut self, req, params, name)`; handlers dispatch by name. *Remaining (deferred
   to storable fns):* per-route *function* binding so the handler isn't a manual `if name == ...` ladder.

2. ~~**Six `run_*` methods**~~ ✅ **SHIPPED 2026-09-04.** `App[M, E, L]` carries middleware / error
   handler / lifecycle as defaulted type parameters (`App(middleware=Chain((a, b)), errors=JsonErrorHandler(),
   lifecycle=hooks)`), and there is one `run` overloaded on the handler trait; `app.handle(handler, req)`
   runs the pipeline in-process for tests. Not a fluent builder chain (a builder must store values of
   unknown type, which Mojo 1.0 cannot) — same ergonomics, order-independent, each part optional. The
   six runners remain as deprecated wrappers until v0.2.

3. ~~**`String("...")` on every literal.**~~ ✅ **SHIPPED (see above)** — implicit `StringLiteral →
   String` was already live in the nightly; docs teach bare literals now. Optional follow-up: strip the
   ~515 legacy wraps from `src/baldr/` (mechanical, guarded by the 460-test suite).

4. ~~**Middleware can't hold state.**~~ ✅ **SHIPPED 2026-09-04.** Both hooks take `mut self`; stages
   are fields of the App (a `Chain` holds them in a `Tuple`) so they are lvalues. `RequestLogger` now
   logs elapsed ms; `RateLimitMW(cooldown_s, what)` is a chain stage keyed on `req.peer`. Conformers
   may still declare `self`.

5. ~~**Concurrency ⟂ everything else.**~~ ✅ **SHIPPED 2026-09-04.** `App.run(handler, workers=N)`
   forks inside `run`; every worker inherits the App and runs the full pipeline (mounts, middleware,
   routes, error handler); `on_startup` runs once in the parent. `run_concurrent` is a deprecated
   wrapper. Per-worker divergence of `mut self` state is documented, with `baldr.db` / `baldr.queue`
   as the shared stores. Keep-alive shipped the same day (`serve_connection`). Worker supervision
   and graceful shutdown shipped the same day: process-wide handler/self-pipe polling, crash-loop-protected
   respawn, active-connection drain, and a configurable grace deadline.

6. ~~**No package manager, no scaffold.**~~ ✅ **SCAFFOLD SHIPPED 2026-09-04.** `pixi run new --
   myapp` creates a pinned, buildable project with the checkout's absolute `src/` include path,
   handler, templates, static files, smoke tests, and a polling `pixi run dev` rebuild/restart loop.
   `--routes` emits the named-route idiom. Publishing baldr as a conda/Mojo package remains blocked
   on that ecosystem's package story; generated READMEs explain how to update the include path when
   moving a checkout.

---

## P1 — Correctness & production-readiness

- ~~**Config is 70% ignored.**~~ ✅ **SHIPPED 2026-09-04.** `App.configure(cfg)` + `app.run(handler, cfg)`
  consume host/port/workers/max_body_bytes/debug/static_dir; `template_dir` is documented as the value
  for `Templates(...)`.
- ~~**`MAX_BODY_BYTES` is not enforced**~~ ✅ **SHIPPED 2026-09-04.** The connection loop answers
  `413 Payload Too Large` from the declared `Content-Length` before reading a body byte (and `431` for
  a header block over 64 KiB); `tests/test_app_config.mojo`.
- ~~**`app.assets(url_prefix=...)` silently ignores `url_prefix`**~~ ✅ **SHIPPED 2026-09-04.** Only paths
  under the mount prefix (segment boundary) are considered; a manifest URL mounted elsewhere falls through.
- ~~**Templates load relative to CWD, not the binary.**~~ ✅ **SHIPPED 2026-09-04.** Relative
  template directories resolve from `BALDR_TEMPLATE_DIR`, beside the executable, one directory
  above it, then CWD; `Templates.root` exposes the selected path. Absolute paths remain unchanged.
- **No TLS / HTTP2** — plaintext HTTP/1.1 only; a reverse proxy (Caddy/nginx) is mandatory, and there
  is zero `X-Forwarded-*`/PROXY-protocol trust handling. Documented; decide if minimal TLS belongs
  in-tree. `app.mojo` accept loop.
- ~~**No worker supervision / graceful shutdown.**~~ ✅ **SHIPPED 2026-09-04.** Dead workers are
  respawned with bounded backoff; SIGTERM/SIGINT drain active connections, reap the pool, run the
  parent lifecycle shutdown hook, and return normally. Five respawns inside 10 seconds terminate a
  crash loop instead of spinning.
- ~~**Body double-parse.**~~ ✅ **SHIPPED 2026-09-04.** `validate()` parses once and
  `ValidationResult.value` exposes that parsed body without a second `json()` call or a breaking
  change to immutable handler requests, `.ok`, or `.to_response()`.
- ~~**`{id}` type errors become 500s.**~~ ✅ **SHIPPED 2026-09-04.** `{id:int}` rejects invalid
  integer segments during matching (404 or later-route fallback); `get_int_or` supplies a
  non-raising read for untyped params.

---

## P2 — Ergonomics & teaching surface

**Testing** — no `Response.text()`/`body_string()` accessor, so every test hand-writes a byte-loop to
read the body; no assertion lib (`assert_status`/`assert_body`) and no `pixi run test` discovery
(suites hand-roll a Runner); `TestClient[H](...)` needs the explicit type param; `RouteTestClient`
skips middleware + static mounts (no in-process test path for them). `testing.mojo`.

**Templates** — `{% extends %}`/`{% block %}` inheritance is **not implemented** and hard-errors
(`unknown statement`), forcing include-only composition; whitespace-control `{%- -%}` doesn't just
miss — it **breaks parsing**; no expression arithmetic (`{{ i + 1 }}`); no `title` filter; missing
keys render empty (silent typos). `template.mojo`.

**JSON** — no struct↔JSON binding (hand-build every object); reads are raw public fields
(`.get(k).string_val`) that yield empty on type mismatch — add `get_string`/`get_int` returning
`Optional`. `json.mojo`.

**Router** — only single-segment `{name}` params (no catch-all, no typed converters); `Match` outcome
is a raw `Int` compared to module constants (add `is_ok()`/`is_not_found()`); `Params.get` does an
O(n) linear scan while `has` is O(1). `router.mojo`.

**Misc** — no cross-compile story (arch footgun: an aarch64 binary won't run on x86); `Response.sse`
is finite-only (no keep-alive/chunked → no true streaming); `Value` constructor naming inconsistent
(`bool_`/`int_`/`float_` vs `string`/`dict`); `with_header` vs `add_header` duplication; `App` has no
`head()` shorthand though `Router` does.

---

## 📚 Audience finding (locked — this is about baldr's users, not just its docs)

**"Docs must teach the Mojo-isms, not assume them."** FastAPI can assume you know Python; baldr can't
assume you know Mojo. Handled via the **Mojo-in-5-Minutes primer** + inline `!!! note` callouts on
each page's first use of a language feature. Keep this pattern — it doubles as course material
(primer ≈ YT video 1: "the 6 Mojo things a Python dev needs").

---

## ✅ Fixed during this pass

- `docs/DESIGN.md` leaked an internal `.claude/.../memory/...` path → removed.
- `docs/reference/templates.md` linked a wrong primer anchor (`#3-ownership-mut-var-out-`) → fixed.

## 🛠 Meta — my own orchestration (not baldr's)

Over-fanned the docs-fill workflow (~14 concurrent Opus writers + Sonnet verifiers) → tripped
Anthropic's **edge rate limiting** ("temporarily limiting requests, not your usage limit"); 6 pages
failed and were finished by hand. Lesson: cap Opus concurrency low and stagger model tiers on
verification-heavy fan-outs, rather than firing every tier at once.

---

## 🛰 Roadmap: the real-time / concurrency arc (surfaced building `logscope`, 2026-07-03)

The single biggest thing baldr can't do today, and the one that unifies several P0/P1/P2 items above:
**hold a connection open and stream to it (SSE / long-poll / WebSocket).** Discovered head-on while
building a real-time dashboard (`~/Projects/Mojo-Data/logscope`): true server-push is impossible on
the current model, and *why* is the interesting part.

**The wall.** baldr's accept loop is **one connection at a time, blocking** (`serve.mojo`: *"one
connection at a time; no keep-alive"*). A held-open SSE stream therefore **deadlocks the server** — while
it holds the stream, it cannot `accept()` the very request (`POST /batch`) whose job is to trigger the
push. And you can't just add threads: **Mojo 1.0 has no safe shared-state threading** — `concurrency.mojo`
chose **prefork** (fork N workers) *for exactly this reason*.

**The way through — prefork + a shared store (no threads required).** With prefork, one worker can
*hold* the SSE stream while the other workers keep serving; they coordinate through a store that lives
**outside** any single process. The natural store is **SQLite** — which also resolves the "how does the
Mojo dashboard read the data" fork by making the DB the single source of truth (what a DB-backed app
wants anyway). Concretely, three real pieces:

1. **`baldr.db` — a `libsqlite3` C-FFI.** `open` / `exec` / `query` → rows. Small, high-value; also
   closes the "baldr has no database story" gap. (De-risk unknown #1: can this nightly dlopen +
   call `libsqlite3` cleanly?)
2. ~~**Chunked / keep-alive streaming in the HTTP layer.**~~ ✅ **SHIPPED 2026-09-04** (`baldr.streaming.ResponseStream`, keep-alive + pipelining in every `run`). Was: today responses are `Content-Length` + close
   (`serve.mojo:377`); add `Transfer-Encoding: chunked`, flush-per-chunk, and a `Response.stream(...)`
   / SSE surface (upgrades the finite `Response.sse`). (De-risk unknown #2: hold the socket open and
   chunk-write on this nightly.)
3. ~~**Prefork + routing + an SSE handler.**~~ ✅ **SHIPPED 2026-09-04** (`run(workers=N)` + `StreamHandler`, `examples/sse`). Was: fix `run_concurrent` so it drives the full App pipeline
   (P0 #5 — today prefork bypasses routes/middleware), and add a streaming handler that long-polls the
   DB (`SELECT … WHERE id > :seen`) and emits `event: batch_done`. htmx's SSE ext (`hx-ext="sse"`,
   `sse-connect`, `hx-trigger="sse:batch_done"`) consumes it.

**This one arc closes:** P0 #5 (concurrency ⟂ routing), the finite-SSE P2 item, "no shared store across
workers" (P1), and "no database story" — plus it unblocks any real-time feature downstream.

**Sequencing.** De-risk unknowns #1 and #2 with a small spike *first*; if either is blocked by Mojo,
fall back to **tight polling + a `GET /version` endpoint** (dashboard polls a cheap counter ~1s, fetches
the fragment only on change — near-real-time, zero framework change). The `logscope` lesson-2 write-up
should teach whichever path we take, and *why* (this analysis is the lesson).
