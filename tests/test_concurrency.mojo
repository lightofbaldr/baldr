"""Phase 2.9 — concurrency (prefork) tests.

The prefork model forks real processes, so the live concurrency (4 parallel
requests in ~1s) is verified via `examples/concurrency` + curl in the CHANGELOG.
These in-process tests verify the plumbing pieces that DON'T need a live
server: the `fork`/`wait`/`getpid` FFI resolves, and a Copyable handler can be
copied per-worker (the precondition for prefork).
"""

from std.collections import Dict

from baldr.request import Request
from baldr.response import Response
from baldr.app import DispatchHandler
from baldr.concurrency import _fork, _wait, _getpid
from std.ffi import external_call, c_int

def _os_exit(code: Int):
    _ = external_call["_exit", c_int, c_int](c_int(code))


@fieldwise_init
struct CopyableHandler(DispatchHandler, Copyable, Movable):
    var tag: String
    var counter: Int

    def __call__(mut self, req: Request) raises -> Response:
        self.counter += 1
        return Response.text(self.tag + String(":") + String(self.counter))


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int
    def __init__(out self):
        self.total = 0
        self.failures = 0
    def check(mut self, label: String, cond: Bool):
        self.total += 1
        if cond:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)
    def summary(self):
        print("---")
        if self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.total - self.failures, "/", self.total, "passed", "—", self.failures, "FAILED")


def main() raises:
    var r = Runner()

    # ── fork/wait/getpid FFI resolves and works ───────────────────────
    var parent_pid = Int(_getpid())
    r.check("getpid returns positive", parent_pid > 0)

    var pid = Int(_fork())
    if pid == 0:
        # child: exit immediately so the parent's wait() reaps it.
        _os_exit(0)
    elif pid > 0:
        r.check("fork returns child pid > 0", pid > 0)
        var reaped = Int(_wait())
        r.check("wait reaps a child (returns pid)", reaped > 0)
    else:
        r.check("fork did not fail", False)

    # ── Copyable handler can be .copy()'d (prefork precondition) ──────
    var h = CopyableHandler(String("worker-a"), 0)
    var h2 = h.copy()
    # mutate the copy independently (simulates per-worker state divergence)
    h2.counter += 1
    r.check("handler copy is independent (h unchanged)", h.counter == 0)
    r.check("handler copy mutated (h2.counter == 1)", h2.counter == 1)

    # both copies handle requests with their own state
    var req = Request(String("GET"), String("/"), String(), String(), Dict[String, String]())
    var resp1 = h(req)
    r.check("original handler served", resp1.status == 200)
    r.check("original handler state mutated", h.counter == 1)
    var resp2 = h2(req)
    r.check("copy handler state independent (h2.counter == 2)", h2.counter == 2)
    r.check("original handler state unaffected by copy (h.counter == 1)", h.counter == 1)

    r.summary()