"""baldr.queue.gpu_store — in-process GPU-backed storage.

`GpuQueue` exposes the same Queue / KV / Tasks / find surface as
`CpuQueue`, but payloads live on the device. SET / PUSH / TPUSH copy
bytes host→device via `cuMemcpyHtoD_v2`; POP / GET / claim copy the
matching window back via `cuMemcpyDtoH_v2`.

Movable but **not Copyable** — the struct owns the dlopen handle, a
`DeviceContext`, and the `DeviceBuffer` that holds the device
allocation. A `Queue` facade can pick this or `CpuQueue` at startup
via `BALDR_QUEUE_BACKEND`.

Single-process / single-thread in v0.1. No locking — callers running
multiple handler threads must guard their own access.
"""

from std.collections import Dict
from std.ffi import OwnedDLHandle, c_size_t
from std.gpu.host import DeviceContext, DeviceBuffer
from std.memory import UnsafePointer

from .cpu import Match
from .gpu import (
    CUdeviceptr, CUresult, HtoDFn, DtoHFn,
    KVRecord, TaskRecord,
    TASK_PENDING, TASK_CLAIMED, TASK_COMPLETED, TASK_FAILED,
    cuda_memcpy_h2d, cuda_memcpy_d2h,
)


struct GpuQueue(Movable, ImplicitlyDestructible):
    """Single-process GPU-backed Queue / KV / Tasks store with the
    same method surface as `CpuQueue`."""
    var capacity: Int
    var tail: Int

    var q_head_idx: Int
    var q_records: List[KVRecord]
    var kv: Dict[String, KVRecord]

    var tasks: Dict[Int, TaskRecord]
    var task_ids: List[Int]
    var next_task_id: Int

    # CUDA resources. Must outlive every method call; ordered so that
    # the handle is closed last on destruction.
    var cuda: OwnedDLHandle
    var htod: HtoDFn
    var dtoh: DtoHFn
    var ctx: DeviceContext
    var dev_buf: DeviceBuffer[DType.uint8]
    var dev_base: UnsafePointer[UInt8, MutAnyOrigin]

    def __init__(out self, capacity: Int = 1024 * 1024 * 1024) raises:
        """Open libcuda, bind the memcpy entry points, allocate the
        device buffer. Raises if libcuda isn't available or the
        allocation fails — callers handle the fallback to CPU."""
        var cuda = OwnedDLHandle("libcuda.so.1")
        var htod = cuda.get_function[HtoDFn]("cuMemcpyHtoD_v2")
        var dtoh = cuda.get_function[DtoHFn]("cuMemcpyDtoH_v2")
        var ctx = DeviceContext()
        var dev_buf = ctx.create_buffer_sync[DType.uint8](capacity)
        var dev_base = dev_buf.unsafe_ptr().bitcast[UInt8]()

        self.capacity = capacity
        self.tail = 0
        self.q_head_idx = 0
        self.q_records = List[KVRecord]()
        self.kv = Dict[String, KVRecord]()
        self.tasks = Dict[Int, TaskRecord]()
        self.task_ids = List[Int]()
        self.next_task_id = 1
        self.cuda = cuda^
        self.htod = htod
        self.dtoh = dtoh
        self.ctx = ctx^
        self.dev_buf = dev_buf^
        self.dev_base = dev_base

    # ── Internal allocator ────────────────────────────────────────────────
    def _write_bytes(mut self, src: UnsafePointer[UInt8, MutAnyOrigin], n: Int) raises -> Int:
        """Append `n` host bytes to the device buffer; return the
        offset where they landed. Raises on capacity exhaustion or
        a memcpy failure."""
        if self.tail + n > self.capacity:
            raise Error(
                String("baldr.queue.gpu: capacity exceeded (")
                + String(self.tail) + " + " + String(n)
                + " > " + String(self.capacity) + ")"
            )
        var dst_offset = self.tail
        if not cuda_memcpy_h2d(self.htod, self.dev_base + dst_offset, src, n):
            raise Error(String("baldr.queue.gpu: cuMemcpyHtoD_v2 failed"))
        self.tail += n
        return dst_offset

    def _read(self, rec: KVRecord) raises -> List[UInt8]:
        """Pull `rec.length` bytes back from the device buffer."""
        var stage = List[UInt8](capacity=rec.length)
        for _ in range(rec.length):
            stage.append(0)
        if not cuda_memcpy_d2h(self.dtoh, stage.unsafe_ptr(),
                               self.dev_base + rec.offset, rec.length):
            raise Error(String("baldr.queue.gpu: cuMemcpyDtoH_v2 failed"))
        return stage^

    # ── Queue API ─────────────────────────────────────────────────────────
    def push(mut self, var payload: List[UInt8]) raises -> Int:
        var offset = self._write_bytes(payload.unsafe_ptr(), len(payload))
        self.q_records.append(KVRecord(offset, len(payload)))
        return offset

    def pop(mut self) raises -> List[UInt8]:
        """Pop the oldest queued payload. Returns an empty list when
        the queue is empty."""
        if self.q_head_idx >= len(self.q_records):
            return List[UInt8]()
        var rec = self.q_records[self.q_head_idx]
        self.q_head_idx += 1
        return self._read(rec)

    def len(self) -> Int:
        return len(self.q_records) - self.q_head_idx

    def queue_bytes(self) -> Int:
        var s = 0
        for i in range(self.q_head_idx, len(self.q_records)):
            s += self.q_records[i].length
        return s

    def kv_count(self) -> Int:
        return len(self.kv)

    # ── KV API ────────────────────────────────────────────────────────────
    def set(mut self, key: String, var payload: List[UInt8]) raises:
        var offset = self._write_bytes(payload.unsafe_ptr(), len(payload))
        self.kv[key] = KVRecord(offset, len(payload))

    def get(self, key: String) raises -> List[UInt8]:
        if not self.kv.__contains__(key):
            return List[UInt8]()
        return self._read(self.kv[key])

    def has(self, key: String) -> Bool:
        return self.kv.__contains__(key)

    def delete(mut self, key: String) raises:
        if self.kv.__contains__(key):
            _ = self.kv.pop(key)

    # ── Tasks API ─────────────────────────────────────────────────────────
    def tpush(mut self, var payload: List[UInt8]) raises -> Int:
        var offset = self._write_bytes(payload.unsafe_ptr(), len(payload))
        var tid = self.next_task_id
        self.next_task_id += 1
        self.tasks[tid] = TaskRecord(offset, len(payload), TASK_PENDING)
        self.task_ids.append(tid)
        return tid

    def claim(mut self) raises -> Int:
        for i in range(len(self.task_ids)):
            var tid = self.task_ids[i]
            if self.tasks.__contains__(tid):
                var rec = self.tasks[tid]
                if rec.status == TASK_PENDING:
                    self.tasks[tid] = TaskRecord(rec.offset, rec.length, TASK_CLAIMED)
                    return tid
        return -1

    def task_payload(self, tid: Int) raises -> List[UInt8]:
        if not self.tasks.__contains__(tid):
            raise Error(String("baldr.queue.gpu: unknown task id ") + String(tid))
        var rec = self.tasks[tid]
        return self._read(KVRecord(rec.offset, rec.length))

    def ack(mut self, tid: Int) raises:
        if not self.tasks.__contains__(tid):
            return
        var rec = self.tasks[tid]
        self.tasks[tid] = TaskRecord(rec.offset, rec.length, TASK_COMPLETED)

    def nack(mut self, tid: Int) raises:
        if not self.tasks.__contains__(tid):
            return
        var rec = self.tasks[tid]
        if rec.status == TASK_CLAIMED:
            self.tasks[tid] = TaskRecord(rec.offset, rec.length, TASK_PENDING)

    def task_status(self, tid: Int) raises -> Int:
        if not self.tasks.__contains__(tid):
            return -1
        return self.tasks[tid].status

    # ── Search ────────────────────────────────────────────────────────────
    def find(self, needle: List[UInt8]) raises -> List[Match]:
        """Substring scan. Pulls the live device buffer back to host
        and runs the same SIMD scan `CpuQueue` uses — host-side scan
        is correct-by-construction and matches `CpuQueue` semantics.
        A CUDA-kernel scan is a v0.2 follow-up."""
        var n = self.tail
        if n == 0 or len(needle) == 0 or len(needle) > n:
            return List[Match]()
        var staged = self._read(KVRecord(0, n))
        return _scan_host(staged, n, needle, len(needle))

    def find_str(self, needle: String) raises -> List[Match]:
        var b = needle.as_bytes()
        var L = List[UInt8](capacity=len(b))
        for i in range(len(b)):
            L.append(b[i])
        return self.find(L)


# ── Host-side SIMD scan (mirrors cpu.mojo's _scan_simd) ───────────────────
comptime _SCAN_WIDTH: Int = 32


def _scan_host(
    data: List[UInt8],
    data_len: Int,
    needle: List[UInt8],
    needle_len: Int,
) -> List[Match]:
    var out = List[Match]()
    if needle_len == 0 or data_len < needle_len:
        return out^

    var first = needle[0]
    var ptr = data.unsafe_ptr()
    var last_start = data_len - needle_len
    var first_vec = SIMD[DType.uint8, _SCAN_WIDTH](first)

    var i: Int = 0
    while i + _SCAN_WIDTH <= last_start + 1:
        var block = (ptr + i).load[width=_SCAN_WIDTH]()
        var eq = block.eq(first_vec)
        if eq.reduce_or():
            for lane in range(_SCAN_WIDTH):
                if eq[lane]:
                    var pos = i + lane
                    if pos <= last_start and _verify(data, pos, needle, needle_len):
                        out.append(Match(pos, needle_len))
        i += _SCAN_WIDTH

    while i <= last_start:
        if data[i] == first and _verify(data, i, needle, needle_len):
            out.append(Match(i, needle_len))
        i += 1
    return out^


def _verify(data: List[UInt8], pos: Int, needle: List[UInt8], needle_len: Int) -> Bool:
    for j in range(needle_len):
        if data[pos + j] != needle[j]:
            return False
    return True
