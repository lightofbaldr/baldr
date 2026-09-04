"""Tests for the `baldr.Queue` facade — env-driven backend selection
+ method-delegation parity with CpuQueue."""

from std.ffi import external_call, c_int

from baldr.queue.api import Queue


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
            print(self.failures, "of", self.total, "FAILED")


def _to_cstring(s: String) -> List[UInt8]:
    var b = (s + "\0").as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _setenv(name: String, value: String):
    var n = _to_cstring(name)
    var v = _to_cstring(value)
    _ = external_call["setenv", c_int](
        n.unsafe_ptr().unsafe_bitcast[Int8](),
        v.unsafe_ptr().unsafe_bitcast[Int8](),
        c_int(1),
    )


def _unsetenv(name: String):
    var n = _to_cstring(name)
    _ = external_call["unsetenv", c_int](n.unsafe_ptr().unsafe_bitcast[Int8]())


def _bytes_to_str(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _str_to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


# ── Env-driven backend selection ──────────────────────────────────────────
def test_local_default_is_cpu(mut r: Runner) raises:
    _unsetenv(String("BALDR_QUEUE_BACKEND"))
    var q = Queue.local()
    r.check(String("default backend == cpu"), q.backend_name() == "cpu")


def test_local_explicit_cpu(mut r: Runner) raises:
    _setenv(String("BALDR_QUEUE_BACKEND"), String("cpu"))
    var q = Queue.local()
    r.check(String("explicit cpu"), q.backend_name() == "cpu")
    _unsetenv(String("BALDR_QUEUE_BACKEND"))


def test_local_auto_always_succeeds(mut r: Runner) raises:
    """`auto` resolves to cpu — the only in-process backend baldr ships.
    Either way the call succeeds."""
    _setenv(String("BALDR_QUEUE_BACKEND"), String("auto"))
    var q = Queue.local()
    var name = q.backend_name()
    r.check(String("auto -> cpu"), name == "cpu")
    _unsetenv(String("BALDR_QUEUE_BACKEND"))


def test_local_case_insensitive(mut r: Runner) raises:
    _setenv(String("BALDR_QUEUE_BACKEND"), String("CPU"))
    var q = Queue.local()
    r.check(String("uppercase CPU accepted"), q.backend_name() == "cpu")
    _unsetenv(String("BALDR_QUEUE_BACKEND"))


def test_local_gpu_raises_with_pointer(mut r: Runner) raises:
    """`gpu` MUST raise since 2026-08-03: the in-process GPU backend moved
    to mojo-gpuq. A web framework does not need device memory for queue
    storage. Deterministic now — no libcuda, no device, no host variance."""
    _setenv(String("BALDR_QUEUE_BACKEND"), String("gpu"))
    var raised = False
    try:
        _ = Queue.local()
    except:
        raised = True
    r.check(String("gpu -> raises (moved to mojo-gpuq)"), raised)
    _unsetenv(String("BALDR_QUEUE_BACKEND"))


def test_local_unknown_raises(mut r: Runner) raises:
    _setenv(String("BALDR_QUEUE_BACKEND"), String("blockchain"))
    var raised = False
    try:
        _ = Queue.local()
    except:
        raised = True
    r.check(String("unknown backend raises"), raised)
    _unsetenv(String("BALDR_QUEUE_BACKEND"))


# ── Method delegation parity ──────────────────────────────────────────────
def test_queue_push_pop(mut r: Runner) raises:
    var q = Queue.cpu_backend()
    _ = q.push(_str_to_bytes(String("hello")))
    _ = q.push(_str_to_bytes(String("world")))
    r.check(String("len 2 after push"), q.len() == 2)
    r.check(String("pop hello"), _bytes_to_str(q.pop()) == "hello")
    r.check(String("pop world"), _bytes_to_str(q.pop()) == "world")
    r.check(String("len 0 after drain"), q.len() == 0)


def test_kv(mut r: Runner) raises:
    var q = Queue.cpu_backend()
    q.set(String("name"), _str_to_bytes(String("adam")))
    r.check(String("has name"), q.has(String("name")))
    r.check(String("get name"), _bytes_to_str(q.get(String("name"))) == "adam")
    q.delete(String("name"))
    r.check(String("absent after delete"), not q.has(String("name")))


def test_tasks(mut r: Runner) raises:
    var q = Queue.cpu_backend()
    var t = q.tpush(_str_to_bytes(String("work")))
    r.check(String("task id > 0"), t > 0)
    var c = q.claim()
    r.check(String("claim returns id"), c == t)
    r.check(String("payload preserved"),
        _bytes_to_str(q.task_payload(t)) == "work")
    q.ack(t)
    r.check(String("status == COMPLETED"), q.task_status(t) == 2)


def test_find(mut r: Runner) raises:
    var q = Queue.cpu_backend()
    q.set(String("doc"), _str_to_bytes(String("hello fox jumps over fox")))
    var matches = q.find_str(String("fox"))
    r.check(String("find via facade"), len(matches) == 2)


def main() raises:
    var r = Runner()

    test_local_default_is_cpu(r)
    test_local_explicit_cpu(r)
    test_local_auto_always_succeeds(r)
    test_local_case_insensitive(r)
    test_local_gpu_raises_with_pointer(r)
    test_local_unknown_raises(r)

    test_queue_push_pop(r)
    test_kv(r)
    test_tasks(r)
    test_find(r)

    r.summary()
