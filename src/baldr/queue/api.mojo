"""baldr.queue.api — backend-agnostic Queue / KV / Tasks facade.

`Queue.local()` reads `BALDR_QUEUE_BACKEND` from the environment and
picks the right backend at startup. CPU and GPU both ship in-process;
the `auto` choice probes `libcuda.so.1` and falls back to CPU if GPU
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
    var store = Queue.gpu_backend(...)        # force GPU; raises if no GPU

Environment:

    BALDR_QUEUE_BACKEND=cpu     # in-process CPU/SIMD (default)
    BALDR_QUEUE_BACKEND=gpu     # in-process GPU via libcuda
    BALDR_QUEUE_BACKEND=auto    # try GPU, fall back to CPU on failure
"""

from ..env import env_str
from .cpu import CpuQueue, Match
from .gpu_store import GpuQueue


comptime BACKEND_CPU: Int = 0
comptime BACKEND_GPU: Int = 1


struct Queue(Movable, ImplicitlyDestructible):
    """Backend-agnostic storage. Holds a `CpuQueue` *or* a `GpuQueue`,
    never both — the other slot is `None`. Not Copyable — the GPU
    backend owns a `DeviceBuffer` and a dlopen handle that have
    unique-owner semantics."""
    var backend: Int
    var cpu_opt: Optional[CpuQueue]
    var gpu_opt: Optional[GpuQueue]

    def __init__(out self, var cpu: CpuQueue):
        self.backend = BACKEND_CPU
        self.cpu_opt = Optional(cpu^)
        self.gpu_opt = Optional[GpuQueue]()

    def __init__(out self, var gpu: GpuQueue):
        self.backend = BACKEND_GPU
        self.cpu_opt = Optional[CpuQueue]()
        self.gpu_opt = Optional(gpu^)

    # ── Factories ─────────────────────────────────────────────────────────
    @staticmethod
    def local(capacity_bytes: Int = 1024 * 1024 * 1024) raises -> Queue:
        """Pick a backend based on the `BALDR_QUEUE_BACKEND` env var."""
        var which = _lowercase(env_str(String("BALDR_QUEUE_BACKEND"), String("cpu")))
        if which == "" or which == "cpu":
            return Queue.cpu_backend(capacity_bytes)
        if which == "gpu":
            return Queue.gpu_backend(capacity_bytes)
        if which == "auto":
            try:
                return Queue.gpu_backend(capacity_bytes)
            except:
                return Queue.cpu_backend(capacity_bytes)
        raise Error(
            String("baldr.queue: unknown BALDR_QUEUE_BACKEND='") + which + "'"
        )

    @staticmethod
    def cpu_backend(capacity_bytes: Int = 1024 * 1024 * 1024) raises -> Queue:
        return Queue(CpuQueue(capacity=capacity_bytes))

    @staticmethod
    def gpu_backend(capacity_bytes: Int = 1024 * 1024 * 1024) raises -> Queue:
        """Raises if libcuda or the device allocation isn't available."""
        return Queue(GpuQueue(capacity=capacity_bytes))

    def backend_name(self) -> String:
        if self.backend == BACKEND_CPU:
            return String("cpu")
        if self.backend == BACKEND_GPU:
            return String("gpu")
        return String("unknown")

    # ── Queue API ─────────────────────────────────────────────────────────
    def push(mut self, var payload: List[UInt8]) raises -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().push(payload^)
        return self.gpu_opt.value().push(payload^)

    def pop(mut self) raises -> List[UInt8]:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().pop()
        return self.gpu_opt.value().pop()

    def len(self) -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().len()
        return self.gpu_opt.value().len()

    def capacity(self) -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().capacity
        return self.gpu_opt.value().capacity

    def tail(self) -> Int:
        """Next free byte in the underlying data buffer. Advances on
        every push / set / tpush — useful for derived ops/sec."""
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().tail
        return self.gpu_opt.value().tail

    def queue_bytes(self) -> Int:
        """Sum of pending-pop queue item lengths."""
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().queue_bytes()
        return self.gpu_opt.value().queue_bytes()

    def kv_count(self) -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().kv_count()
        return self.gpu_opt.value().kv_count()

    # ── KV API ────────────────────────────────────────────────────────────
    def set(mut self, key: String, var payload: List[UInt8]) raises:
        if self.backend == BACKEND_CPU:
            self.cpu_opt.value().set(key, payload^)
        else:
            self.gpu_opt.value().set(key, payload^)

    def get(self, key: String) raises -> List[UInt8]:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().get(key)
        return self.gpu_opt.value().get(key)

    def has(self, key: String) -> Bool:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().has(key)
        return self.gpu_opt.value().has(key)

    def delete(mut self, key: String) raises:
        if self.backend == BACKEND_CPU:
            self.cpu_opt.value().delete(key)
        else:
            self.gpu_opt.value().delete(key)

    # ── Tasks API ─────────────────────────────────────────────────────────
    def tpush(mut self, var payload: List[UInt8]) raises -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().tpush(payload^)
        return self.gpu_opt.value().tpush(payload^)

    def claim(mut self) raises -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().claim()
        return self.gpu_opt.value().claim()

    def task_payload(self, tid: Int) raises -> List[UInt8]:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().task_payload(tid)
        return self.gpu_opt.value().task_payload(tid)

    def ack(mut self, tid: Int) raises:
        if self.backend == BACKEND_CPU:
            self.cpu_opt.value().ack(tid)
        else:
            self.gpu_opt.value().ack(tid)

    def nack(mut self, tid: Int) raises:
        if self.backend == BACKEND_CPU:
            self.cpu_opt.value().nack(tid)
        else:
            self.gpu_opt.value().nack(tid)

    def task_status(self, tid: Int) raises -> Int:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().task_status(tid)
        return self.gpu_opt.value().task_status(tid)

    # ── Search ────────────────────────────────────────────────────────────
    def find(self, needle: List[UInt8]) raises -> List[Match]:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().find(needle)
        return self.gpu_opt.value().find(needle)

    def find_str(self, needle: String) raises -> List[Match]:
        if self.backend == BACKEND_CPU:
            return self.cpu_opt.value().find_str(needle)
        return self.gpu_opt.value().find_str(needle)


def _lowercase(s: String) -> String:
    var out = String()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            c += 32
        out += chr(c)
    return out^
