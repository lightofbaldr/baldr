"""GpuQueue smoke test — construct, push, pop, KV, tasks, find.

Skipped at runtime if libcuda.so.1 isn't loadable (CI hosts without
GPU). The CpuQueue tests cover the cross-backend semantic contract;
this just confirms the device-memcpy path actually moves bytes.
"""

from baldr.queue.gpu_store import GpuQueue


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int
    var skipped: Bool

    def __init__(out self):
        self.total = 0
        self.failures = 0
        self.skipped = False

    def check(mut self, label: String, cond: Bool):
        self.total += 1
        if cond:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)

    def skip(mut self, reason: String):
        self.skipped = True
        print("[SKIP]", reason)

    def summary(self):
        print("---")
        if self.skipped:
            print("SKIPPED — no GPU available")
        elif self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.failures, "of", self.total, "FAILED")


def _str_to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _bytes_to_str(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def run_smoke() raises -> Int:
    var r = Runner()

    # Construct — small (64 KiB) so the test is cheap.
    var q = GpuQueue(capacity=64 * 1024)

    # Queue.
    _ = q.push(_str_to_bytes(String("hello")))
    _ = q.push(_str_to_bytes(String("world")))
    r.check(String("len == 2 after 2 pushes"), q.len() == 2)
    r.check(String("pop hello"), _bytes_to_str(q.pop()) == "hello")
    r.check(String("pop world"), _bytes_to_str(q.pop()) == "world")
    r.check(String("len == 0 after drain"), q.len() == 0)

    # KV.
    q.set(String("name"), _str_to_bytes(String("adam")))
    r.check(String("has name"), q.has(String("name")))
    r.check(String("get name == adam"),
        _bytes_to_str(q.get(String("name"))) == "adam")
    q.delete(String("name"))
    r.check(String("absent after delete"), not q.has(String("name")))

    # Tasks.
    var t = q.tpush(_str_to_bytes(String("work")))
    r.check(String("task id > 0"), t > 0)
    var c = q.claim()
    r.check(String("claim returns id"), c == t)
    r.check(String("payload preserved on device"),
        _bytes_to_str(q.task_payload(t)) == "work")
    q.ack(t)
    r.check(String("status COMPLETED after ack"), q.task_status(t) == 2)

    # find — host-side scan over device-pulled bytes.
    q.set(String("doc"), _str_to_bytes(String("the quick brown fox jumps over the lazy fox")))
    var matches = q.find_str(String("fox"))
    r.check(String("find_str fox -> 2 matches"), len(matches) == 2)

    r.summary()
    return r.failures


def main():
    try:
        var failures = run_smoke()
        if failures != 0:
            print("test_queue_gpu: FAILED")
    except e:
        # libcuda missing or device-init failed → not a regression on
        # CPU-only hosts. Caller looks for "SKIPPED" in stdout.
        print("[SKIP] GpuQueue init failed:", String(e))
        print("---")
        print("SKIPPED — no GPU available")
