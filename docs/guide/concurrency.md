# Concurrency

A single accept loop serves one request at a time. That's fine for a demo and fine for I/O that finishes in microseconds — but the moment one handler does something slow (reads a big file, waits on a subprocess, runs a model), every other client sits in line behind it.

baldr's answer is **prefork**: the parent binds the socket, then `fork()`s several worker processes that all `accept()` on that same listening socket. The kernel load-balances new connections across them. It's the classic nginx / old-Apache model, and it's the honest concurrency story for Mojo 1.0 today.

!!! note "Why processes, not threads? (a Mojo-1.0 reality)"
    Mojo 1.0 has no `std.threading`, and a `DispatchHandler` is `mut self` — a single handler instance can't be safely mutated from several threads at once. Prefork sidesteps both: each worker gets its **own copy** of the handler, in its own process. No threads, no locks, no data races. A thread-pool variant waits on a future Mojo with stable threads. See the [Mojo primer](../mojo-primer.md) for the ownership model that makes this the natural choice.

## The one function

Concurrency lives in its own module, separate from `App`. You call `run_concurrent` instead of `App().run(...)`:

```mojo
from baldr.concurrency import run_concurrent
```

Its signature:

```mojo
def run_concurrent[H: DispatchHandler & Copyable](
    var handler: H,
    host: String = "0.0.0.0",
    port: Int = 8080,
    workers: Int = 4,
) raises:
```

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `handler` | `H` (owned) | — | Your `DispatchHandler` struct — the same trait you already write |
| `host` | `String` | `"0.0.0.0"` | Bind address (informational in the log line; the socket binds `0.0.0.0`) |
| `port` | `Int` | `8080` | Port to bind |
| `workers` | `Int` | `4` | Number of worker processes to fork |

The one extra requirement over `App().run` is in the parameter bound: `[H: DispatchHandler & Copyable]`. Your handler must be **`Copyable`**, because each worker gets an independent `handler.copy()`. If you already write `struct MyApp(DispatchHandler, Copyable, Movable)` — and every example in these docs does — you're done.

!!! note "What's `[H: DispatchHandler & Copyable]`? (Mojo generics)"
    The bracket is a **compile-time parameter**: `run_concurrent` is generic over your handler type `H`, and `& Copyable` says `H` must satisfy *both* the `DispatchHandler` and `Copyable` traits. You never write the bracket at the call site — Mojo infers `H` from the value you pass. See the [primer](../mojo-primer.md) on structs and traits.

## A complete example

Here is `examples/concurrency/main.mojo` in full — a deliberately slow handler behind a 4-worker pool:

```mojo
from baldr.concurrency import run_concurrent
from baldr.request import Request
from baldr.response import Response
from baldr.app import DispatchHandler
from std.ffi import external_call, c_uint, c_int


def _sleep_s(s: Int):
    _ = external_call["sleep", c_uint, c_uint](c_uint(s))


@fieldwise_init
struct SlowHandler(DispatchHandler, Copyable, Movable):
    var tag: String

    def __call__(mut self, req: Request) raises -> Response:
        if req.path == "/slow" and req.method == "GET":
            _sleep_s(1)   # 1s of work
            return Response.text(
                "served by " + self.tag
                + " (pid "
                + String(Int(external_call["getpid", c_int]()))
                + ")\n"
            )
        if req.path == "/" and req.method == "GET":
            return Response.text("ok\n")
        return Response.text("404\n", 404)


def main() raises:
    run_concurrent(SlowHandler("baldr-prefork"), port=8099, workers=4)
```

Nothing about the handler is special — it's an ordinary `DispatchHandler`. Only `main` changes: `run_concurrent(...)` in place of `App().run(...)`.

Build and run it:

```console
$ pixi run example-concurrency && build/example-concurrency
[baldr] prefork: 4 workers on 0.0.0.0 port 8099 (parent pid 40112 )
[baldr] worker 0 pid 40113 ready
[baldr] worker 1 pid 40114 ready
[baldr] worker 2 pid 40115 ready
[baldr] worker 3 pid 40116 ready
```

Each request sleeps a full second. Fire four at once and watch them finish together, not in series:

```console
$ for i in 1 2 3 4; do curl -s http://127.0.0.1:8099/slow & done; wait
served by baldr-prefork (pid 40114)
served by baldr-prefork (pid 40115)
served by baldr-prefork (pid 40113)
served by baldr-prefork (pid 40116)
```

Four one-second requests, ~1 second wall-clock total instead of ~4. The `pid` in each reply is the worker that served it — proof the kernel spread the load. A fifth concurrent request would queue behind whichever worker frees up first, because each worker still runs a **serial** accept loop internally.

To stop the pool, Ctrl-C the parent — the whole process group dies together.

## The rule that comes with it: no shared mutable state

This is the part to internalize. Each worker owns a *separate copy* of your handler in a *separate process*. Memory is not shared. So if your handler mutates `self`, those mutations are **per-worker** and will diverge:

```mojo
@fieldwise_init
struct Counter(DispatchHandler, Copyable, Movable):
    var hits: Int

    def __call__(mut self, req: Request) raises -> Response:
        self.hits += 1                       # ⚠️ counts THIS worker's hits only
        return Response.text(String(self.hits) + "\n")
```

Behind `App().run` (one process) this counts every request. Behind `run_concurrent(..., workers=4)` you get four independent counters, and which one you see depends on which worker the kernel handed your connection to. The count will look like it's "going backwards" as you refresh.

!!! warning "Per-process state is the trade-off, not a bug"
    Prefork buys you lock-free parallelism by giving up shared memory. Stateless handlers (static files, reads, stateless APIs) parallelize *for free* with zero code changes. Handlers that need a shared count, cache, or session store must put that state somewhere all workers can reach — see below. This is the deliberate v0.9 trade: correctness and simplicity over shared-memory cleverness.

### Where shared state goes

When several workers genuinely need to agree on something (a chat app's message list, a global rate limit, a hit counter), move that state **out of the handler struct** and into a store all processes can reach:

- **[`baldr.queue`](queue.md)** — the bundle's own concurrent-access subsystem, designed for exactly this. Keep your per-process handler stateless and let the queue hold the shared work.
- **An external store** — Redis, Postgres, a file with locking. The same answer FastAPI gives you when you scale past one Uvicorn worker.

The mental model is identical to running FastAPI under Gunicorn with `--workers 4`: your process-local globals are per-worker; anything shared lives in a backing service.

## When to reach for it

| Situation | Use |
|---|---|
| Learning, local dev, low traffic | `App().run(...)` — one loop, simplest |
| Handlers are stateless and you want throughput | `run_concurrent(..., workers=N)` |
| Handlers do slow work (files, subprocess, model) | `run_concurrent(...)` so one slow request doesn't block the rest |
| Handlers need shared mutable state | `run_concurrent(...)` **plus** [`baldr.queue`](queue.md) or an external store |

A reasonable starting point for `workers` is your core count. More workers means more parallel slow-request slots but also more memory — each is a full process copy of your program.

## Honest limits (today)

baldr is pre-alpha, and `run_concurrent` is the smallest thing that correctly parallelizes. What it is **not**, yet:

!!! warning "What prefork does not give you yet"
    - **No graceful shutdown / worker supervision.** The parent `wait()`s for children; if a worker dies, it is **not** re-spawned, and there's no drain-then-exit on a signal. Ctrl-C kills the whole group. A supervisor loop is roadmap.
    - **No middleware / routes / error-handler / lifecycle path.** `run_concurrent` calls `handler(req)` directly — the same shape as `App().run`, *not* `run_routes_middleware` or `run_full`. If your app is built on routes, middleware, or lifecycle hooks, prefork can't drive it today. Composing the full `App` pipeline with prefork is the obvious next step and is on the punch-list.
    - **No static / asset mounts.** Because it bypasses `App`, the `app.static(...)` and asset-manifest mounts aren't consulted. Serve those from a stateless handler branch or a separate `App().run` process for now.
    - **Still one connection at a time per worker.** Each worker's accept loop is serial and there's no keep-alive — `workers=N` gives you N in-flight requests, not N per worker.
    - **Config is positional.** `workers` is a plain keyword arg; there's no `ServeConfig`-style object wiring host/port/workers together, and no env-var override. (`ServeConfig` exists in `baldr.serve`, but it's the static-file CLI's config — not `run_concurrent`'s.)

None of these are hard blocks for the target use case — a stateless or queue-backed API that needs to not block on slow work. They're exactly the rough edges we're tracking, and they'll fill in as the pipeline and `App` converge on the prefork runner.

---

Next: put shared state where the workers can all reach it — **[The Queue →](queue.md)**.
