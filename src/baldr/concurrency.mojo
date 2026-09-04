"""baldr.concurrency — prefork worker pool (now `App.run(handler, workers=N)`).

The honest pure-Mojo concurrency model for Mojo 1.0 is **prefork** (the
classic nginx / old-Apache model), not threads:

  - Parent: `socket_create` → `bind` → `listen`, `lifecycle.on_startup()`,
    then `fork()` N workers.
  - Each worker: `accept()` on the shared listening socket (the kernel
    load-balances across workers) and runs the serial accept loop with
    the App and handler it inherited by fork — the full pipeline: static
    mounts, assets, middleware, routes, error handler.
  - Parent: `wait()` for children; on Ctrl-C the whole process group dies.

Why prefork, not pthreads: Mojo 1.0 has no `std.threading`, and handlers and
middleware are `mut self`. Prefork gives each worker its own process, so
there is NO shared mutable state and NO mutex — and also no shared memory:
a handler that mutates `self` (counter, cache, rate-limit table) diverges
per worker by design. Shared state belongs in `baldr.db` (SQLite, one
file, every worker) or `baldr.queue`.

Since 2026-09-04 the pool lives on the App: `app.run(handler, port=8080,
workers=4)`. `run_concurrent` below is the v0.1 entry point, kept as a
deprecated wrapper until v0.2.
"""

from std.ffi import c_int

from .app import App, DispatchHandler
from .http import process_fork, process_wait, process_getpid


def _fork() -> c_int:
    return process_fork()


def _wait() -> c_int:
    """wait() for any child to exit. Returns the child pid (>0) or -1."""
    return process_wait()


def _getpid() -> c_int:
    return process_getpid()


def run_concurrent[H: DispatchHandler & Copyable](
    var handler: H,
    host: String = String("0.0.0.0"),
    port: Int = 8080,
    workers: Int = 4,
) raises:
    """Deprecated: `app.run(handler, host=host, port=port, workers=workers)`.

    Kept for v0.1 call sites. The `Copyable` bound is no longer needed —
    workers inherit the handler by fork — but is retained so existing
    signatures still match."""
    var app = App()
    app.run(handler^, host, port, workers)
