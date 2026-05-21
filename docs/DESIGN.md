# baldr — design notes

Contributor-facing context for the v0.1 implementation.

## Why a bundle

Each of `mojo-http` / `mojo-serve` / `mojo-template` / `mojo-json` /
`mojo-gpuq` is a focused, single-purpose package that ships and
versions on its own. The bundle exists for two reasons:

1. **Developer experience.** A FastAPI-shaped one-import quickstart
   is the thing people try first. Asking them to compose five
   packages by hand before they can render a JSON response loses the
   first-impression battle.
2. **Single binary out.** `pixi run example-hello` compiles to one
   static binary with no Python on the request path. That story breaks
   if the bundle is itself a thin shim that pulls live dependencies —
   so v0.1 vendors the underlying packages under `src/baldr/`.

The vendored layout means that bumping a vendored package is a
deliberate `git diff`, not a transitive lockfile churn. The downside:
the bundle drifts from the upstream packages unless someone watches
both. v0.2+ revisits this once Mojo's package registry lands.

## Layer map

```
examples/hello, chat, scan         <- single-file binaries
        ^
        |
baldr.app                          <- App + DispatchHandler trait + accept loop
baldr.middleware.{logger, ratelimit, security_headers}
baldr.request / baldr.response     <- v0.1 public API surface
baldr.templates                    <- filesystem wrapper around baldr.template
        ^
        |   vendored (Phase 1):
baldr.http       (mojo-http)       <- POSIX sockets, HTTP/1.1 parse
baldr.serve      (mojo-serve)      <- static-file dispatch, safe path joins, MIME
baldr.template   (mojo-template)   <- lexer, parser, eval, render, filters
baldr.json       (mojo-json)       <- RFC 8259 parse + emit
baldr.queue.gpu  (mojo-gpuq)       <- GPU-resident store + TCP server
baldr.queue.cpu  (new, Phase 3)    <- CPU/SIMD store, same API shape
baldr.queue.client (vendored)      <- TCP client for queue.remote()
```

Phase 1 vendoring kept the vendored modules **byte-identical** to
upstream where possible. The only material edits:

- `def main()` → `def _demo()` in `http.mojo`, `serve.mojo`,
  `queue/gpu.mojo` so they parse as library modules.
- `queue/client.mojo`: one pre-existing lvalue typecheck error in
  `gpuq_claim()` (passing a temporary to a `mut` parameter) — fixed
  with a `var cmd = …` binding.

Everything else is namespace-only adjustment (sibling-import paths,
`from baldr.X import Y` style).

## Trait-based dispatch (Phase 5 revision)

The v0.1 routing story landed twice. The first attempt (Phase 2) used
a comptime function-pointer parameter (`App.run[dispatch](…)`). Mojo
1.0.0b2 doesn't auto-convert named `def` functions to anonymous `def(...)`
type aliases, and the `escaping` function effect that the changelog
documented is no longer supported. So Phase 5 replaced the pattern
with a `DispatchHandler` trait:

```mojo
trait DispatchHandler(Copyable, Movable, ImplicitlyDestructible):
    def __call__(mut self, req: Request) raises -> Response: ...
```

Users implement the trait on a struct:

```mojo
@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    var greeting: String

    def __call__(mut self, req: Request) raises -> Response:
        ...

def main() raises:
    app.run(HelloApp(String("hi")), port=8080)
```

The trait pattern actually turned out **better** than function-pointer
storage would have been:

- **Handlers own their state.** Rate limiters, queues, template caches,
  in-memory message lists — they all live as struct fields on the
  dispatcher. No global mutables, no UnsafePointer dance for
  shared state.
- **`mut self` works.** Setting the trait method as `mut self` means
  state mutations across requests persist (e.g. chat's `messages`
  list, ratelimit's `last_hit_s` dict).
- **Comptime monomorphic dispatch.** `App.run[H: DispatchHandler]`
  specializes per concrete handler type — no vtable indirection per
  request.

The cost: no runtime-registered per-route `.get/.post/.put/.delete`
in v0.1. The user does method/path matching inside their
`__call__`. Per-route registration lands in v0.2 once Mojo's
function-pointer-storage story stabilizes (function aliases stored in
a list, or a trait-object pattern for routes).

## Storage backend symmetry

`baldr.queue.cpu.CpuQueue` and `baldr.queue.gpu` (vendored mojo-gpuq)
share the same record layout:

```mojo
struct CpuKVRecord:    var offset: Int ; var length: Int
struct CpuTaskRecord:  var offset, length, status: Int
# matches:
struct KVRecord:       var offset: Int ; var length: Int    (gpu.mojo)
struct TaskRecord:     var offset, length, status: Int      (gpu.mojo)
```

This is deliberate: a future `baldr.Queue` facade can pick the
backend at construction time (`Queue.local()` → GPU if available, CPU
otherwise) and dispatch through a shared trait without divergent
record shapes. The trait isn't drawn yet — Phase 3 only shipped the
CPU side — but the symmetry means the facade is mostly plumbing when
it's time.

## SIMD substring scan

Two-stage pattern, default width 32 (`SIMD[DType.uint8, 32]`):

```
while i + 32 <= last_match_start + 1:
    block = data_ptr.load[width=32](i)
    eq = block.eq(broadcast(needle[0]))
    if eq.reduce_or():
        for lane in 0..32: if eq[lane] and verify(...): emit(i+lane)
    i += 32
# scalar tail for the remainder
```

`SIMD == SIMD` in Mojo 1.0 returns a **scalar Bool** (any-equal), not
an elementwise mask. Use `.eq()` for elementwise comparison returning
`SIMD[bool, N]`, then `.reduce_or()` to short-circuit, `[lane]` to
verify per-lane hits.

The scalar verify path only runs when `needle[0]` matches somewhere
in the 32-byte block — the bench shows that hit-dense workloads are
~3 % slower than miss-only, which means the scalar tail isn't
dominating. See [`PERF.md`](PERF.md) for measured throughput.

## Memory model

All three stores — queue, KV, tasks — share a single `data:
List[UInt8]` buffer. `tail` is the next free byte; `push` / `set` /
`tpush` all grow `tail`. Records (queue/KV/task entries) point into
the buffer via `(offset, length)`.

This is **append-only in v0.1**: an overwrite of `set("k", new)` leaks
the prior bytes — `kv["k"]` still resolves to the new value, but the
old bytes stay in `data` between `0..tail`. Compaction lands in v0.2;
the design is to walk `q_records ∪ kv.values ∪ tasks.values`,
mark live regions, slide live ranges down, rebuild record offsets in
one pass. The append-only invariant makes `find()` straightforward:
scan over `data[0..tail]` and return offsets directly.

Pop and delete advance pointers / drop dict entries but don't free
bytes. `len()` is `len(q_records) - q_head_idx`, which keeps pop O(1).

## Mojo 1.0 quirks worth knowing

These bit us during the build and are documented in
[`feedback_mojo_v1_syntax`](../../.claude/projects/-home-adam/memory/feedback_mojo_v1_syntax.md):

- `fn` keyword **removed** — use `def` for both function declarations
  and function-type aliases.
- `alias X = …` **deprecated** — use `comptime X = …`.
- `from pathlib` → `from std.pathlib`. `from collections` → `from
  std.collections`. `from sys.ffi` → `from std.ffi`.
- `SIMD == SIMD` returns scalar `Bool`. Elementwise compare is `.eq()`.
- `UnsafePointer[T].offset(i)` is gone — use `(ptr + i)`.
- `Path` has no `.mkdir()` / `.rmdir()` — use `std.os.mkdir` / `makedirs`.
- Module-level mutables disallowed (use struct state).
- `List[T]` is **not** `ImplicitlyCopyable` — explicit `.copy()` or
  `^` (move) is required for assignment.

## Repo discipline

- One commit per phase (Phase 0 → Phase 6+); commit messages cite
  the phase number.
- `pixi run test` must be green before commit.

## Where to look first

- New to the codebase: read `src/baldr/app.mojo` and one of the
  examples in `examples/`.
- Touching storage: read `src/baldr/queue/cpu.mojo` end-to-end —
  it's the cleanest reference for the record layout the GPU side
  also follows.
- Touching the framework: trait conformance is in `app.mojo`; the
  middleware helpers (`security_headers`, `ratelimit`, `logger`) are
  the example pattern for stateless / state-local helpers.
- Adding a test: copy `tests/test_queue_cpu.mojo` — the `Runner`
  struct pattern is the convention.
