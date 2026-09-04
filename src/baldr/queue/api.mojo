"""baldr.queue.api — backend-agnostic Queue / KV / Tasks facade.

`Queue.local()` reads `BALDR_QUEUE_BACKEND` from the environment and
selects the storage backend at startup. baldr ships ONE in-process
backend — CPU/SIMD. The GPU backend moved to mojo-gpuq on 2026-08-03
construction fails. Remote queues (TCP) come in via `Queue.remote()`
in v0.2.

The public method surface is identical to `CpuQueue.*` — push / pop /
len, set / get / has / delete, tpush / claim / ack / nack /
task_status / task_payload, find / find_str — so user code holding
a `Queue` doesn't change when the backend changes.

Usage:

    from baldr.queue import Queue

    var store = Queue.local()                 # honors BALDR_QUEUE_BACKEND
    var store = Queue.cpu_backend(...)        # force CPU/SIMD
    var store = Queue.cpu_backend(...)        # explicit CPU

Environment:

    BALDR_QUEUE_BACKEND=cpu     # in-process CPU/SIMD (default)
    BALDR_QUEUE_BACKEND=auto    # resolves to cpu (only in-process backend)
    BALDR_QUEUE_BACKEND=gpu     # raises, with a pointer to mojo-gpuq
"""

from ..env import env_str
from .cpu import CpuQueue, Match


comptime BACKEND_CPU: Int = 0


struct Queue(Movable, Deinitable):
    """Storage facade over the in-process CPU/SIMD backend.

    Kept as a facade even with a single backend: it is the seam where an
    out-of-process mojo-gpuq client can reappear as a backend without
    changing any caller. Not Copyable — `CpuQueue` has unique-owner
    semantics."""
    var backend: Int
    var cpu_opt: Optional[CpuQueue]

    def __init__(out self, var cpu: CpuQueue):
        self.backend = BACKEND_CPU
        self.cpu_opt = Optional(cpu^)

    # ── Factories ─────────────────────────────────────────────────────────
    @staticmethod
    def local(capacity_bytes: Int = 1024 * 1024 * 1024) raises -> Queue:
        """Pick a backend based on the `BALDR_QUEUE_BACKEND` env var."""
        var which = _lowercase(env_str(String("BALDR_QUEUE_BACKEND"), String("cpu")))
        if which == "" or which == "cpu":
            return Queue.cpu_backend(capacity_bytes)
        if which == "auto":
            # Only one in-process backend ships in baldr; `auto` resolves to it.
            return Queue.cpu_backend(capacity_bytes)
        if which == "gpu":
            raise Error(
                String(
                    "baldr.queue: the in-process GPU backend was moved out of "
                    "baldr (2026-08-03). A web framework does not need device "
                    "memory for queue storage, and the GPU backend carried the "
                    "package's only CUDA/dlopen surface. It now lives in "
                    "mojo-gpuq and is reachable as a SUBSYSTEM over its TCP "
                    "protocol. Use BALDR_QUEUE_BACKEND=cpu."
                )
            )
        raise Error(
            String("baldr.queue: unknown BALDR_QUEUE_BACKEND='") + which + "'"
        )

    @staticmethod
    def cpu_backend(capacity_bytes: Int = 1024 * 1024 * 1024) raises -> Queue:
        return Queue(CpuQueue(capacity=capacity_bytes))


    def backend_name(self) -> String:
        if self.backend == BACKEND_CPU:
            return String("cpu")
        return String("unknown")

    # ── Queue API ─────────────────────────────────────────────────────────
    def push(mut self, var payload: List[UInt8]) raises -> Int:
        return self.cpu_opt.value().push(payload^)

    def pop(mut self) raises -> List[UInt8]:
        return self.cpu_opt.value().pop()

    def len(self) -> Int:
        return self.cpu_opt.value().len()

    def capacity(self) -> Int:
        return self.cpu_opt.value().capacity

    def tail(self) -> Int:
        """Next free byte in the underlying data buffer. Advances on
        every push / set / tpush — useful for derived ops/sec."""
        return self.cpu_opt.value().tail

    def queue_bytes(self) -> Int:
        """Sum of pending-pop queue item lengths."""
        return self.cpu_opt.value().queue_bytes()

    def kv_count(self) -> Int:
        return self.cpu_opt.value().kv_count()

    # ── KV API ────────────────────────────────────────────────────────────
    def set(mut self, key: String, var payload: List[UInt8]) raises:
        self.cpu_opt.value().set(key, payload^)

    def get(self, key: String) raises -> List[UInt8]:
        return self.cpu_opt.value().get(key)

    def has(self, key: String) -> Bool:
        return self.cpu_opt.value().has(key)

    def delete(mut self, key: String) raises:
        self.cpu_opt.value().delete(key)

    # ── Tasks API ─────────────────────────────────────────────────────────
    def tpush(mut self, var payload: List[UInt8]) raises -> Int:
        return self.cpu_opt.value().tpush(payload^)

    def claim(mut self) raises -> Int:
        return self.cpu_opt.value().claim()

    def task_payload(self, tid: Int) raises -> List[UInt8]:
        return self.cpu_opt.value().task_payload(tid)

    def ack(mut self, tid: Int) raises:
        self.cpu_opt.value().ack(tid)

    def nack(mut self, tid: Int) raises:
        self.cpu_opt.value().nack(tid)

    def task_status(self, tid: Int) raises -> Int:
        return self.cpu_opt.value().task_status(tid)

    # ── Search ────────────────────────────────────────────────────────────
    def find(self, needle: List[UInt8]) raises -> List[Match]:
        return self.cpu_opt.value().find(needle)

    def find_str(self, needle: String) raises -> List[Match]:
        return self.cpu_opt.value().find_str(needle)


def _lowercase(s: String) -> String:
    var out = String()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            c += 32
        out += chr(c)
    return out^
