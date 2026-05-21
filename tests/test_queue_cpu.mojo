"""Phase 3 — CPU/SIMD storage backend.

Covers queue / KV / tasks semantics plus the SIMD substring scan
across the full data buffer (queue + KV + tasks share storage).
"""

from baldr.queue.cpu import (
    CpuQueue, Match,
    TASK_PENDING, TASK_CLAIMED, TASK_COMPLETED,
)


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


# ── Queue ─────────────────────────────────────────────────────────────────
def test_queue_basic(mut r: Runner) raises:
    var q = CpuQueue()
    r.check(String("empty len == 0"), q.len() == 0)
    _ = q.push(_str_to_bytes(String("hello")))
    _ = q.push(_str_to_bytes(String("world")))
    r.check(String("len after 2 pushes"), q.len() == 2)

    var a = q.pop()
    r.check(String("first pop = hello"), _bytes_to_str(a) == "hello")
    var b = q.pop()
    r.check(String("second pop = world"), _bytes_to_str(b) == "world")
    r.check(String("len after drain"), q.len() == 0)

    var c = q.pop()
    r.check(String("empty pop returns []"), len(c) == 0)


def test_queue_capacity(mut r: Runner) raises:
    var q = CpuQueue(capacity=8)
    _ = q.push(_str_to_bytes(String("12345678")))
    var raised = False
    try:
        _ = q.push(_str_to_bytes(String("X")))
    except:
        raised = True
    r.check(String("capacity overflow raises"), raised)


# ── KV ────────────────────────────────────────────────────────────────────
def test_kv_basic(mut r: Runner) raises:
    var q = CpuQueue()
    r.check(String("absent key has=False"), not q.has(String("name")))

    q.set(String("name"), _str_to_bytes(String("adam")))
    r.check(String("has after set"), q.has(String("name")))
    r.check(String("get returns adam"), _bytes_to_str(q.get(String("name"))) == "adam")

    q.set(String("color"), _str_to_bytes(String("blue")))
    r.check(String("two keys live"), _bytes_to_str(q.get(String("color"))) == "blue")

    # Overwrite (v0.1 append-only — old bytes leak, lookup follows new).
    q.set(String("name"), _str_to_bytes(String("eve")))
    r.check(String("overwrite reads new"), _bytes_to_str(q.get(String("name"))) == "eve")

    q.delete(String("color"))
    r.check(String("delete removes key"), not q.has(String("color")))
    r.check(String("get-missing returns []"), len(q.get(String("color"))) == 0)


# ── Tasks ─────────────────────────────────────────────────────────────────
def test_tasks_basic(mut r: Runner) raises:
    var q = CpuQueue()

    var t1 = q.tpush(_str_to_bytes(String("task-one")))
    var t2 = q.tpush(_str_to_bytes(String("task-two")))
    r.check(String("first id > 0"), t1 > 0)
    r.check(String("ids increasing"), t2 > t1)
    r.check(String("status PENDING"), q.task_status(t1) == TASK_PENDING)

    var c = q.claim()
    r.check(String("claim returns first id"), c == t1)
    r.check(String("status CLAIMED"), q.task_status(t1) == TASK_CLAIMED)
    r.check(String("payload preserved"),
        _bytes_to_str(q.task_payload(t1)) == "task-one")

    q.ack(t1)
    r.check(String("ack → COMPLETED"), q.task_status(t1) == TASK_COMPLETED)

    var c2 = q.claim()
    r.check(String("second claim returns t2"), c2 == t2)
    q.nack(t2)
    r.check(String("nack returns to PENDING"), q.task_status(t2) == TASK_PENDING)
    var c3 = q.claim()
    r.check(String("nacked task re-claimable"), c3 == t2)

    var c4 = q.claim()
    r.check(String("no more claimable"), c4 == -1)


# ── SIMD substring scan ───────────────────────────────────────────────────
def test_find_basic(mut r: Runner) raises:
    var q = CpuQueue()
    q.set(String("doc"), _str_to_bytes(String("the quick brown fox jumps over the lazy dog")))

    var matches = q.find_str(String("fox"))
    r.check(String("find single match"), len(matches) == 1)
    r.check(String("offset points at fox"),
        len(matches) == 1 and matches[0].offset == 16)


def test_find_multi(mut r: Runner) raises:
    var q = CpuQueue()
    q.set(String("a"), _str_to_bytes(String("the cat sat on the mat")))
    var matches = q.find_str(String("the"))
    r.check(String("two 'the' matches"), len(matches) == 2)


def test_find_no_match(mut r: Runner) raises:
    var q = CpuQueue()
    q.set(String("a"), _str_to_bytes(String("hello world")))
    var matches = q.find_str(String("zzz"))
    r.check(String("no matches returns empty"), len(matches) == 0)


def test_find_empty_needle(mut r: Runner) raises:
    var q = CpuQueue()
    q.set(String("a"), _str_to_bytes(String("hello world")))
    var matches = q.find_str(String(""))
    r.check(String("empty needle returns empty"), len(matches) == 0)


def test_find_across_stores(mut r: Runner) raises:
    """Queue + KV + Tasks all share `data`, so find() spans all of them."""
    var q = CpuQueue()
    _ = q.push(_str_to_bytes(String("MARKER from queue")))
    q.set(String("key"), _str_to_bytes(String("MARKER from kv")))
    _ = q.tpush(_str_to_bytes(String("MARKER from task")))

    var matches = q.find_str(String("MARKER"))
    r.check(String("three MARKER hits across stores"), len(matches) == 3)


def test_find_long_buffer(mut r: Runner) raises:
    """Build a >SCAN_WIDTH (32-byte) buffer with one needle inside the
    SIMD region and one in the scalar tail — confirms both stages."""
    var q = CpuQueue()
    var pad = String()
    for _ in range(80):
        pad += "."
    q.set(String("a"), _str_to_bytes(pad + "FOUND" + pad + "FOUND"))
    var matches = q.find_str(String("FOUND"))
    r.check(String("two hits across SIMD + tail"), len(matches) == 2)


def test_find_edge_alignment(mut r: Runner) raises:
    """Match starting right at the SIMD/tail boundary doesn't get missed."""
    var q = CpuQueue()
    var pad = String()
    for _ in range(30):  # 30 bytes — match at offset 30 crosses width=32 boundary
        pad += "."
    q.set(String("a"), _str_to_bytes(pad + "BOUNDARY"))
    var matches = q.find_str(String("BOUNDARY"))
    r.check(String("boundary-crossing match found"),
        len(matches) == 1 and matches[0].offset == 30)


def main() raises:
    var r = Runner()

    test_queue_basic(r)
    test_queue_capacity(r)

    test_kv_basic(r)

    test_tasks_basic(r)

    test_find_basic(r)
    test_find_multi(r)
    test_find_no_match(r)
    test_find_empty_needle(r)
    test_find_across_stores(r)
    test_find_long_buffer(r)
    test_find_edge_alignment(r)

    r.summary()
