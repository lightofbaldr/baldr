"""baldr.queue.cpu — CPU + SIMD persistence backend.

Same Queue / KV / Tasks surface as the GPU backend, but with host-side
storage. The substring scan (`find`) uses `SIMD[DType.uint8, 32]` for
~memmem-class throughput on modern CPUs (AVX2 / Neon).

v0.1 is append-only: SET / PUSH / TPUSH all grow `tail`. KV overwrite
leaks the prior bytes; compaction lands in v0.2. The queue's head
pointer advances on POP — list isn't resized so POP stays O(1).
"""

from std.collections import Dict
from std.memory import UnsafePointer


# ── Records ───────────────────────────────────────────────────────────────
@fieldwise_init
struct CpuKVRecord(Copyable, ImplicitlyCopyable, Movable):
    """Pointer into `CpuQueue.data` for one stored item."""
    var offset: Int
    var length: Int


# Task status enum — plain ints for Movable simplicity.
comptime TASK_PENDING:   Int = 0
comptime TASK_CLAIMED:   Int = 1
comptime TASK_COMPLETED: Int = 2
comptime TASK_FAILED:    Int = 3


@fieldwise_init
struct CpuTaskRecord(Copyable, ImplicitlyCopyable, Movable):
    var offset: Int
    var length: Int
    var status: Int


@fieldwise_init
struct Match(Copyable, ImplicitlyCopyable, Movable):
    """One occurrence of `needle` inside the store. `offset` is the
    byte position in the underlying data buffer; `length` mirrors the
    needle length for callers that want to slice straight from it."""
    var offset: Int
    var length: Int


# ── SIMD substring scan ───────────────────────────────────────────────────
comptime SCAN_WIDTH: Int = 32  # SIMD[DType.uint8, 32] — see SPEC §6


def _scan_simd(
    data: List[UInt8],
    data_len: Int,
    needle: List[UInt8],
    needle_len: Int,
) -> List[Match]:
    """Two-stage scan: SIMD broadcast-and-compare on needle[0], then
    scalar verify on hits. Returns matches in ascending offset order."""
    var out = List[Match]()
    if needle_len == 0 or data_len < needle_len:
        return out^

    var first = needle[0]
    var data_ptr = data.unsafe_ptr()
    var last_start = data_len - needle_len

    # SIMD body — process SCAN_WIDTH bytes at a time, stopping early
    # enough that any reported offset still has room for the full
    # needle inside data_len.
    var first_vec = SIMD[DType.uint8, SCAN_WIDTH](first)
    var i: Int = 0
    while i + SCAN_WIDTH <= last_start + 1:
        var block = (data_ptr + i).load[width=SCAN_WIDTH]()
        var eq = block.eq(first_vec)
        if eq.reduce_or():
            # At least one lane matched. Verify each lane scalarly.
            for lane in range(SCAN_WIDTH):
                if eq[lane]:
                    var pos = i + lane
                    if pos <= last_start and _verify(data, pos, needle, needle_len):
                        out.append(Match(pos, needle_len))
        i += SCAN_WIDTH

    # Scalar tail for the remainder.
    while i <= last_start:
        if data[i] == first and _verify(data, i, needle, needle_len):
            out.append(Match(i, needle_len))
        i += 1
    return out^


def _verify(
    data: List[UInt8],
    pos: Int,
    needle: List[UInt8],
    needle_len: Int,
) -> Bool:
    """Confirm the full needle matches data starting at `pos`."""
    for j in range(needle_len):
        if data[pos + j] != needle[j]:
            return False
    return True


# ── The store ─────────────────────────────────────────────────────────────
struct CpuQueue(Copyable, Movable):
    """Single-process Queue / KV / Tasks store with SIMD substring
    search. Public via `baldr.Queue` once the GPU/CPU facade lands."""
    var capacity: Int

    # Append-only payload buffer. `tail` is the next free byte; SET /
    # PUSH / TPUSH all grow it.
    var data: List[UInt8]
    var tail: Int

    # FIFO queue.
    var q_head_idx: Int
    var q_records: List[CpuKVRecord]

    # KV store.
    var kv: Dict[String, CpuKVRecord]

    # Task table.
    var tasks: Dict[Int, CpuTaskRecord]
    var task_ids: List[Int]   # insertion order; used by claim()
    var next_task_id: Int

    def __init__(out self, capacity: Int = 1024 * 1024 * 1024):
        self.capacity = capacity
        self.data = List[UInt8](capacity=4096)
        self.tail = 0
        self.q_head_idx = 0
        self.q_records = List[CpuKVRecord]()
        self.kv = Dict[String, CpuKVRecord]()
        self.tasks = Dict[Int, CpuTaskRecord]()
        self.task_ids = List[Int]()
        self.next_task_id = 1

    # ── Internal allocator ────────────────────────────────────────────────
    def _allocate(mut self, var payload: List[UInt8]) raises -> CpuKVRecord:
        var n = len(payload)
        if self.tail + n > self.capacity:
            raise Error(String("baldr.queue.cpu: capacity exceeded (")
                        + String(self.tail) + " + " + String(n) + " > "
                        + String(self.capacity) + ")")
        var offset = self.tail
        for i in range(n):
            self.data.append(payload[i])
        self.tail += n
        return CpuKVRecord(offset, n)

    def _read(self, rec: CpuKVRecord) -> List[UInt8]:
        var out = List[UInt8](capacity=rec.length)
        for i in range(rec.length):
            out.append(self.data[rec.offset + i])
        return out^

    # ── Queue API ─────────────────────────────────────────────────────────
    def push(mut self, var payload: List[UInt8]) raises -> Int:
        """Push bytes onto the queue. Returns the byte offset where
        the payload was stored — same shape as the GPU backend."""
        var rec = self._allocate(payload^)
        self.q_records.append(rec)
        return rec.offset

    def pop(mut self) -> List[UInt8]:
        """Pop the oldest queued payload. Returns an empty list if the
        queue is empty — callers should check len() first if the
        distinction matters."""
        if self.q_head_idx >= len(self.q_records):
            return List[UInt8]()
        var rec = self.q_records[self.q_head_idx]
        self.q_head_idx += 1
        return self._read(rec)

    def len(self) -> Int:
        return len(self.q_records) - self.q_head_idx

    def queue_bytes(self) -> Int:
        """Sum of pending-pop item lengths. Useful for STATS-style probes."""
        var s = 0
        for i in range(self.q_head_idx, len(self.q_records)):
            s += self.q_records[i].length
        return s

    def kv_count(self) -> Int:
        return len(self.kv)

    # ── KV API ────────────────────────────────────────────────────────────
    def set(mut self, key: String, var payload: List[UInt8]) raises:
        var rec = self._allocate(payload^)
        self.kv[key] = rec

    def get(self, key: String) raises -> List[UInt8]:
        """Returns the stored bytes, or an empty list if the key is
        absent. Raises only on internal corruption — missing keys are
        a normal flow."""
        if not self.kv.__contains__(key):
            return List[UInt8]()
        var rec = self.kv[key]
        return self._read(rec)

    def has(self, key: String) -> Bool:
        return self.kv.__contains__(key)

    def delete(mut self, key: String) raises:
        if self.kv.__contains__(key):
            _ = self.kv.pop(key)

    # ── Tasks API ─────────────────────────────────────────────────────────
    def tpush(mut self, var payload: List[UInt8]) raises -> Int:
        """Push a task. Returns its assigned task ID."""
        var rec = self._allocate(payload^)
        var tid = self.next_task_id
        self.next_task_id += 1
        self.tasks[tid] = CpuTaskRecord(rec.offset, rec.length, TASK_PENDING)
        self.task_ids.append(tid)
        return tid

    def claim(mut self) raises -> Int:
        """Claim the oldest PENDING task. Returns the task ID or -1
        if the queue is empty. The payload can be fetched via
        `task_payload(id)`."""
        for i in range(len(self.task_ids)):
            var tid = self.task_ids[i]
            if self.tasks.__contains__(tid):
                var rec = self.tasks[tid]
                if rec.status == TASK_PENDING:
                    self.tasks[tid] = CpuTaskRecord(
                        rec.offset, rec.length, TASK_CLAIMED)
                    return tid
        return -1

    def task_payload(self, tid: Int) raises -> List[UInt8]:
        if not self.tasks.__contains__(tid):
            raise Error(String("baldr.queue.cpu: unknown task id ") + String(tid))
        var rec = self.tasks[tid]
        return self._read(CpuKVRecord(rec.offset, rec.length))

    def ack(mut self, tid: Int) raises:
        if not self.tasks.__contains__(tid):
            return
        var rec = self.tasks[tid]
        self.tasks[tid] = CpuTaskRecord(rec.offset, rec.length, TASK_COMPLETED)

    def nack(mut self, tid: Int) raises:
        """Return a claimed task to PENDING so another worker can pick
        it up. No-op if the task was completed or unknown."""
        if not self.tasks.__contains__(tid):
            return
        var rec = self.tasks[tid]
        if rec.status == TASK_CLAIMED:
            self.tasks[tid] = CpuTaskRecord(rec.offset, rec.length, TASK_PENDING)

    def task_status(self, tid: Int) raises -> Int:
        if not self.tasks.__contains__(tid):
            return -1
        return self.tasks[tid].status

    # ── Search ────────────────────────────────────────────────────────────
    def find(self, needle: List[UInt8]) -> List[Match]:
        """SIMD-accelerated substring scan over the entire data buffer.
        Returns matches in ascending offset order across all stores
        (queue + KV + tasks share `data`)."""
        return _scan_simd(self.data, self.tail, needle, len(needle))

    def find_str(self, needle: String) -> List[Match]:
        """Convenience over `find` for String needles."""
        var b = needle.as_bytes()
        var n = List[UInt8](capacity=len(b))
        for i in range(len(b)):
            n.append(b[i])
        return self.find(n)
