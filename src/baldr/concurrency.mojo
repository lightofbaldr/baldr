"""baldr.concurrency — prefork worker pool.

Phase 2.9 — concurrency. The honest pure-Mojo concurrency model for Mojo
1.0: **prefork** (the classic nginx/old-Apache model), not threads.

  - Parent: `socket_create` → `bind` → `listen`, then `fork()` N workers.
  - Each worker: `accept()` on the shared listening socket (the kernel
    load-balances across workers) and runs a serial accept loop with its
    OWN `handler.copy()`.
  - Parent: `wait()` for children. On Ctrl-C the whole process group dies.

Why prefork, not pthreads:
  - Mojo 1.0 has no `std.threading`, and passing a trait-object handler
    through a C `pthread_create` `void*` is impractical.
  - The `DispatchHandler` model is `mut self` — a single handler instance
    can't be safely mutated across threads. Prefork gives each worker its
    own copy (requires `Copyable`), so there is NO shared mutable state
    and NO mutex needed. Stateless handlers parallelize trivially.
  - Workers that need shared state (e.g. a chat app's message list) move
    that state into the `baldr.queue` subsystem (already designed for
    concurrent access) or an external store, and keep their per-process
    handler stateless.

Trade-off: prefork uses more memory (N process copies) than threads, and
shared state needs a real backing store rather than in-process mutation.
That's the right trade for v0.9 — correctness over memory savings, and
the stateless hot path (static files, reads, stateless APIs) parallelizes
for free. A future Mojo with stable threads + trait objects can add a
thread-pool variant.
"""

from std.ffi import external_call, c_int

from .http import (
    socket_create, socket_reuseaddr, make_sockaddr_in,
    socket_bind, socket_listen, socket_accept, socket_close,
    read_request, write_all,
)
from .request import Request, parse_request
from .response import Response
from .app import DispatchHandler


def _fork() -> c_int:
    return external_call["fork", c_int]()


def _wait() -> c_int:
    """wait() for any child to exit. Returns the child pid (>0) or -1."""
    return external_call["wait", c_int, c_int](c_int(0))


def _getpid() -> c_int:
    return external_call["getpid", c_int]()


def run_concurrent[H: DispatchHandler & Copyable](
    var handler: H,
    host: String = String("0.0.0.0"),
    port: Int = 8080,
    workers: Int = 4,
) raises:
    """Start a prefork worker pool. Each of `workers` child processes runs
    a serial accept loop on the shared listening socket with its own
    `handler.copy()`. The parent waits for children.

    `H` must be `Copyable` so each worker gets an independent copy. Handlers
    that mutate `self` (e.g. an in-memory counter) will diverge per worker —
    move such state into `baldr.queue` or an external store for consistency.
    """
    var sock = socket_create()
    if Int(sock) < 0:
        raise Error(String("baldr: socket() failed"))
    _ = socket_reuseaddr(sock)
    var addr = make_sockaddr_in(port)
    if not socket_bind(sock, addr):
        socket_close(sock)
        raise Error(String("baldr: bind() failed on port ") + String(port))
    if not socket_listen(sock):
        socket_close(sock)
        raise Error(String("baldr: listen() failed"))

    print("[baldr] prefork:", workers, "workers on", host, "port", port, "(parent pid", Int(_getpid()), ")")

    # Fork N workers.
    var pids = List[Int]()
    for i in range(workers):
        var pid = Int(_fork())
        if pid == 0:
            # ── worker ───────────────────────────────────────────────
            var my_handler = handler.copy()
            print("[baldr] worker", i, "pid", Int(_getpid()), "ready")
            while True:
                var client = socket_accept(sock)
                if Int(client) < 0:
                    continue
                var raw = read_request(client)
                if len(raw) == 0:
                    socket_close(client)
                    continue
                var resp: Response
                try:
                    var req = parse_request(raw)
                    resp = my_handler(req)
                except e:
                    resp = Response.text(String("500 ") + String(e) + "\n", 500)
                var resp_bytes = resp.to_bytes()
                write_all(client, resp_bytes)
                socket_close(client)
        elif pid > 0:
            pids.append(pid)
        else:
            raise Error(String("baldr: fork() failed"))

    # ── parent: wait for children (they run forever; this blocks until
    #    the process group is killed, e.g. by Ctrl-C). ─────────────────
    var alive = workers
    while alive > 0:
        var w = Int(_wait())
        if w > 0:
            alive -= 1
        else:
            break
