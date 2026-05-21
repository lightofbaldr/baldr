"""mojo-gpuq — a pure-Mojo queue server that keeps its data in GPU memory.

Like Python's RQ, but the queue lives in HBM instead of in Redis. The
server holds one large `DeviceBuffer[UInt8]` on a single GPU; clients
connect over TCP and push / pop opaque byte payloads. Per-item lengths
and head/tail offsets live in host memory; the payload bytes themselves
live in GPU memory and are read/written via `cudaMemcpy`.

Why this is worth building:

- HBM is roughly 3 TB/s on Blackwell-class hardware; DDR5 is ~100 GB/s.
  For hot data that flows between workers and producers, putting the
  queue in HBM is a real bandwidth story.

- If the workers reading the queue are themselves ML kernels, the data
  is already on the device the kernel will consume it from — no PCIe
  round-trip back to host RAM.

- Multi-GPU sharding (Gold's 3-GPU configuration) becomes natural:
  each device is a shard, the server sits in front. v0.1.

What's in v0.0.1:

- One device buffer, configurable size (default 1 GiB).
- Append-only ring layout: `tail` grows; OOM when tail hits capacity.
  Compaction / wrap-around is v0.1.
- Single-threaded TCP accept loop on port 6379 (Redis's port — the
  joke is intentional).
- Four commands: `PUSH <N>`, `POP`, `LEN`, `STATS`.
- One client at a time. No keep-alive. Connection-per-command.

What's NOT in v0.0.1 (queued for v0.1+):

- Compaction / wrap-around / multi-segment storage.
- Multi-GPU sharding across the 3-GPU host.
- KV (hash table) semantics in addition to queue.
- Task queue semantics: ack / retry / dead-letter / status.
- Disk persistence and replication.
- A Mojo worker client library.
- GPU-side scan kernels (the real future bandwidth win — search
  the entire queue without bringing data back to host).
- Concurrent connections / event loop.
- Authentication / authorization.

Build:
    pixi run build              → build/gpuq-server   (~MB Mojo binary)

Use:
    GPUQ_PORT=6379 GPUQ_CAPACITY_MB=1024 ./build/gpuq-server

Wire protocol (text + raw bytes, one command per connection):

    PUSH N\r\n<N bytes><any-trailing>      → "+OK <offset>\r\n"
    POP\r\n                                → "$N\r\n<N bytes>\r\n"   (or "$-1\r\n" if empty)
    LEN\r\n                                → ":<count>\r\n"
    STATS\r\n                              → "+OK capacity=<C> used=<U> count=<N>\r\n"
"""

from std.collections import Dict
from std.ffi import OwnedDLHandle, c_int, c_size_t, external_call
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext, DeviceBuffer
from std.memory import UnsafePointer
from std.os.env import getenv


# ── Socket constants ────────────────────────────────────────────────────
comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1
comptime SOL_SOCKET: c_int = 1
comptime SO_REUSEADDR: c_int = 2

comptime DEFAULT_PORT: Int = 6379  # same as Redis, on purpose
comptime DEFAULT_CAPACITY_MB: Int = 1024  # 1 GiB
comptime LISTEN_BACKLOG: c_int = 16
comptime READ_BUFFER_SIZE: Int = 65536

# We talk to CUDA via the Driver API. Neither libcudart nor libcuda is
# in the link line of a `mojo build` output, so we open them at runtime
# via `OwnedDLHandle` and hold the function pointers for the duration
# of the server. CUdeviceptr is unsigned 64-bit on the platforms we
# support (linux-aarch64 / linux-x86_64).
alias CUdeviceptr = UInt64
alias CUresult = Int32

alias HtoDFn = def (CUdeviceptr, UnsafePointer[UInt8, MutAnyOrigin], c_size_t) thin abi("C") -> CUresult
alias DtoHFn = def (UnsafePointer[UInt8, MutAnyOrigin], CUdeviceptr, c_size_t) thin abi("C") -> CUresult


# ── Socket primitives (the mojo-http vintage) ───────────────────────────
def socket_create() -> c_int:
    return external_call["socket", c_int, c_int, c_int, c_int](
        AF_INET, SOCK_STREAM, c_int(0)
    )


def socket_reuseaddr(fd: c_int) -> Bool:
    var one: c_int = 1
    var rc = external_call[
        "setsockopt", c_int,
        c_int, c_int, c_int,
        UnsafePointer[c_int, origin_of(one)], c_int,
    ](fd, SOL_SOCKET, SO_REUSEADDR, UnsafePointer(to=one), c_int(4))
    return Int(rc) == 0


def make_sockaddr_in(port: Int) -> List[UInt8]:
    var addr = List[UInt8](capacity=16)
    for _ in range(16):
        addr.append(0)
    addr[0] = UInt8(2)  # AF_INET
    addr[2] = UInt8((port >> 8) & 0xFF)
    addr[3] = UInt8(port & 0xFF)
    return addr^


def socket_bind(fd: c_int, mut addr: List[UInt8]) -> Bool:
    var rc = external_call[
        "bind", c_int,
        c_int, UnsafePointer[UInt8, origin_of(addr)], c_int,
    ](fd, addr.unsafe_ptr(), c_int(16))
    return Int(rc) == 0


def socket_listen(fd: c_int) -> Bool:
    var rc = external_call["listen", c_int, c_int, c_int](fd, LISTEN_BACKLOG)
    return Int(rc) == 0


def socket_accept(fd: c_int) -> c_int:
    var peer_addr = List[UInt8](capacity=16)
    var peer_len = List[UInt8](capacity=4)
    for _ in range(16):
        peer_addr.append(0)
    peer_len.append(16); peer_len.append(0); peer_len.append(0); peer_len.append(0)
    return external_call[
        "accept", c_int,
        c_int,
        UnsafePointer[UInt8, origin_of(peer_addr)],
        UnsafePointer[UInt8, origin_of(peer_len)],
    ](fd, peer_addr.unsafe_ptr(), peer_len.unsafe_ptr())


def socket_close(fd: c_int) -> None:
    _ = external_call["close", c_int, c_int](fd)


def recv_some(fd: c_int, mut buf: List[UInt8], max_bytes: Int) -> Int:
    """Read up to max_bytes into `buf`, appending. Returns bytes read."""
    var tmp = List[UInt8](capacity=max_bytes)
    for _ in range(max_bytes):
        tmp.append(0)
    var n = external_call[
        "recv", c_size_t,
        c_int, UnsafePointer[UInt8, origin_of(tmp)], c_size_t, c_int,
    ](fd, tmp.unsafe_ptr(), c_size_t(max_bytes), c_int(0))
    var got = Int(n)
    if got <= 0:
        return 0
    for i in range(got):
        buf.append(tmp[i])
    return got


def recv_exactly(fd: c_int, mut buf: List[UInt8], need: Int) -> Bool:
    """Block until exactly `need` more bytes have been appended to `buf`,
    or the peer closes. Returns False on short read."""
    var got: Int = 0
    while got < need:
        var n = recv_some(fd, buf, need - got)
        if n <= 0:
            return False
        got += n
    return True


def send_all(fd: c_int, mut data: List[UInt8]):
    var total: Int = 0
    var n = len(data)
    while total < n:
        var sent = external_call[
            "send", c_size_t,
            c_int, UnsafePointer[UInt8, origin_of(data)], c_size_t, c_int,
        ](fd, data.unsafe_ptr() + total, c_size_t(n - total), c_int(0))
        if Int(sent) <= 0:
            return
        total += Int(sent)


def send_str(fd: c_int, s: String):
    var b = s.as_bytes()
    var lst = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        lst.append(b[i])
    send_all(fd, lst)


# ── CUDA memcpy via FFI ─────────────────────────────────────────────────
# Mojo's DeviceContext API copies whole buffers. For ring-buffer offset
# writes we drop to the CUDA Runtime API directly. cudaMemcpy is the
# blocking variant — synchronous, which is what we want at the byte
# level for a request/response server.

def cuda_memcpy_h2d(htod: HtoDFn,
                    dst_dev: UnsafePointer[UInt8, MutAnyOrigin],
                    src_host: UnsafePointer[UInt8, MutAnyOrigin],
                    count: Int) -> Bool:
    var rc = htod(CUdeviceptr(Int(dst_dev)), src_host, c_size_t(count))
    return Int(rc) == 0


def cuda_memcpy_d2h(dtoh: DtoHFn,
                    dst_host: UnsafePointer[UInt8, MutAnyOrigin],
                    src_dev: UnsafePointer[UInt8, MutAnyOrigin],
                    count: Int) -> Bool:
    var rc = dtoh(dst_host, CUdeviceptr(Int(src_dev)), c_size_t(count))
    return Int(rc) == 0


# ── Record types ────────────────────────────────────────────────────────
@fieldwise_init
struct KVRecord(Copyable, ImplicitlyCopyable, Movable):
    """A pointer into the device buffer for one KV entry. Two ints, so
    safe to mark `ImplicitlyCopyable` — Dict[String, KVRecord] reads
    return copies. The queue's per-item records use the same shape."""
    var offset: Int
    var length: Int


# Task status enum. Plain ints because Mojo 1.0 enums are evolving and
# the ServerState struct needs to be trivially copyable.
comptime TASK_PENDING:   Int = 0
comptime TASK_CLAIMED:   Int = 1
comptime TASK_COMPLETED: Int = 2
comptime TASK_FAILED:    Int = 3


@fieldwise_init
struct TaskRecord(Copyable, ImplicitlyCopyable, Movable):
    """A task: an opaque payload in GPU memory plus its lifecycle state."""
    var offset: Int
    var length: Int
    var status: Int


# ── Server state ────────────────────────────────────────────────────────
struct ServerState(Copyable, Movable):
    """All host-side bookkeeping for the GPU-backed store.

    Append-only allocation: SET / PUSH / TPUSH all grow `tail_offset`.
    Old KV values become unreachable after overwrite — we leak the
    bytes for v0.0.1; compaction lands in v0.1.

    Queue:
      `q_records` is the FIFO of (offset, length) records in push order.
      `q_head_idx` advances on POP — list isn't resized, keeps POP O(1).
      We track offsets explicitly because KV writes also advance
      `tail_offset`, so the queue's bytes aren't necessarily contiguous
      with each other in the device buffer.

    KV:
      `kv` maps key → (offset, length).

    Shared:
      `capacity`     total device buffer size.
      `tail_offset`  next free byte in the device buffer.
      `htod` / `dtoh` cached CUDA memcpy function pointers.
    """
    var capacity: Int
    var tail_offset: Int

    var q_head_idx: Int
    var q_records: List[KVRecord]

    var kv: Dict[String, KVRecord]

    # Task table: ID → record. Task IDs auto-increment from 1.
    var tasks: Dict[Int, TaskRecord]
    var next_task_id: Int

    var htod: HtoDFn
    var dtoh: DtoHFn

    def __init__(out self, capacity: Int, htod: HtoDFn, dtoh: DtoHFn):
        self.capacity = capacity
        self.tail_offset = 0
        self.q_head_idx = 0
        self.q_records = List[KVRecord]()
        self.kv = Dict[String, KVRecord]()
        self.tasks = Dict[Int, TaskRecord]()
        self.next_task_id = 1
        self.htod = htod
        self.dtoh = dtoh

    def queue_count(self) -> Int:
        return len(self.q_records) - self.q_head_idx

    def queue_bytes_in_flight(self) -> Int:
        """Sum of pending-pop item lengths. Used for STATS."""
        var s = 0
        for i in range(self.q_head_idx, len(self.q_records)):
            s += self.q_records[i].length
        return s


# ── Protocol parsing ────────────────────────────────────────────────────
def find_crlf(buf: List[UInt8], start: Int) -> Int:
    """Return the byte index of \\r\\n at or after `start`, or -1."""
    var n = len(buf)
    var i = start
    while i + 1 < n:
        if buf[i] == UInt8(13) and buf[i + 1] == UInt8(10):
            return i
        i += 1
    return -1


def slice_to_string(buf: List[UInt8], lo: Int, hi: Int) -> String:
    var lst = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        lst.append(buf[i])
    return String(unsafe_from_utf8=lst[:])


# ── Command handling ────────────────────────────────────────────────────
def _gpu_write(
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    src: UnsafePointer[UInt8, MutAnyOrigin],
    n: Int,
) -> Int:
    """Append `n` bytes to the device buffer; return the offset they
    landed at, or -1 if capacity is exhausted / the memcpy failed."""
    if state.tail_offset + n > state.capacity:
        return -1
    var dst_offset = state.tail_offset
    if not cuda_memcpy_h2d(state.htod, dev_base + dst_offset, src, n):
        return -1
    state.tail_offset += n
    return dst_offset


def _gpu_read(
    state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    offset: Int,
    n: Int,
) -> Optional[List[UInt8]]:
    var stage = List[UInt8](capacity=n)
    for _ in range(n):
        stage.append(0)
    if not cuda_memcpy_d2h(state.dtoh, stage.unsafe_ptr(), dev_base + offset, n):
        return None
    return Optional(stage^)


def handle_push(
    client_fd: c_int,
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    payload_len: Int,
    mut buf: List[UInt8],
    consumed_through: Int,
):
    """`PUSH N\\r\\n<N bytes>` — append N bytes to the queue."""
    var have_in_buf = len(buf) - consumed_through
    var still_need = payload_len - have_in_buf
    if still_need > 0:
        if not recv_exactly(client_fd, buf, still_need):
            send_str(client_fd, String("-ERR short read\r\n"))
            return

    var offset = _gpu_write(state, dev_base, buf.unsafe_ptr() + consumed_through, payload_len)
    if offset < 0:
        send_str(client_fd, String("-ERR capacity exhausted\r\n"))
        return

    state.q_records.append(KVRecord(offset, payload_len))
    send_str(client_fd, String("+OK ") + String(offset) + "\r\n")


def handle_pop(
    client_fd: c_int,
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
):
    """`POP\\r\\n` — pull the head item back to host and ship it."""
    if state.q_head_idx >= len(state.q_records):
        send_str(client_fd, String("$-1\r\n"))
        return
    var rec = state.q_records[state.q_head_idx]
    var read = _gpu_read(state, dev_base, rec.offset, rec.length)
    if not read:
        send_str(client_fd, String("-ERR memcpy device→host failed\r\n"))
        return
    var stage = read.take()
    state.q_head_idx += 1
    send_str(client_fd, String("$") + String(rec.length) + "\r\n")
    send_all(client_fd, stage)
    send_str(client_fd, String("\r\n"))


def handle_len(client_fd: c_int, state: ServerState):
    send_str(client_fd, String(":") + String(state.queue_count()) + "\r\n")


def handle_stats(client_fd: c_int, state: ServerState):
    var msg = String("+OK capacity=") + String(state.capacity) \
            + " tail="              + String(state.tail_offset) \
            + " queue_count="       + String(state.queue_count()) \
            + " queue_bytes="       + String(state.queue_bytes_in_flight()) \
            + " kv_count="          + String(len(state.kv)) \
            + "\r\n"
    send_str(client_fd, msg)


def handle_bench_bandwidth(
    client_fd: c_int,
    state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    size_bytes: Int,
):
    """`BENCH_BANDWIDTH <N>\\r\\n` — measure raw H2D + D2H throughput.

    Allocates an N-byte host buffer, times one cuMemcpyHtoD_v2 into the
    *tail-end* of the device buffer (so we never overlap with live
    queue / KV / task records that grow from offset 0), then times one
    cuMemcpyDtoH_v2 back. Returns the wall-clock nanoseconds for each
    leg plus the size, in a single "+OK" line.

    The bench writes to `dev_base + capacity - size`. If `size` exceeds
    capacity, we error out — this is a pure micro-bench, not a real op.
    """
    if size_bytes <= 0 or size_bytes > state.capacity:
        send_str(client_fd, String("-ERR bench size out of range\r\n"))
        return

    # Stage a host buffer of `size_bytes` filled with a deterministic byte.
    var host_buf = List[UInt8](capacity=size_bytes)
    for _ in range(size_bytes):
        host_buf.append(UInt8(0x5A))

    var dev_offset = state.capacity - size_bytes
    var dev_ptr = dev_base + dev_offset

    # Time H2D.
    var t0 = perf_counter_ns()
    var ok_h2d = cuda_memcpy_h2d(state.htod, dev_ptr, host_buf.unsafe_ptr(), size_bytes)
    var t1 = perf_counter_ns()
    if not ok_h2d:
        send_str(client_fd, String("-ERR H2D memcpy failed\r\n"))
        return

    # Time D2H back into the same buffer (overwrites the 0x5A fill, fine).
    var ok_d2h = cuda_memcpy_d2h(state.dtoh, host_buf.unsafe_ptr(), dev_ptr, size_bytes)
    var t2 = perf_counter_ns()
    if not ok_d2h:
        send_str(client_fd, String("-ERR D2H memcpy failed\r\n"))
        return

    var h2d_ns = Int(t1 - t0)
    var d2h_ns = Int(t2 - t1)

    var msg = String("+OK bytes=") + String(size_bytes) \
            + " h2d_ns=" + String(h2d_ns) \
            + " d2h_ns=" + String(d2h_ns) \
            + "\r\n"
    send_str(client_fd, msg)


# ── KV handlers ─────────────────────────────────────────────────────────
def handle_set(
    client_fd: c_int,
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    key: String,
    payload_len: Int,
    mut buf: List[UInt8],
    consumed_through: Int,
):
    """`SET <key> <N>\\r\\n<N bytes>` — store value at key. Overwrites if
    the key already exists; the previous bytes leak in v0.0.1."""
    var have_in_buf = len(buf) - consumed_through
    var still_need = payload_len - have_in_buf
    if still_need > 0:
        if not recv_exactly(client_fd, buf, still_need):
            send_str(client_fd, String("-ERR short read\r\n"))
            return

    var offset = _gpu_write(state, dev_base, buf.unsafe_ptr() + consumed_through, payload_len)
    if offset < 0:
        send_str(client_fd, String("-ERR capacity exhausted\r\n"))
        return

    state.kv[key] = KVRecord(offset, payload_len)
    send_str(client_fd, String("+OK\r\n"))


def handle_get(
    client_fd: c_int,
    state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    key: String,
) raises:
    """`GET <key>\\r\\n` → "$N\\r\\n<bytes>\\r\\n" or "$-1\\r\\n"."""
    if key not in state.kv:
        send_str(client_fd, String("$-1\r\n"))
        return
    var rec = state.kv[key]
    var read = _gpu_read(state, dev_base, rec.offset, rec.length)
    if not read:
        send_str(client_fd, String("-ERR memcpy device→host failed\r\n"))
        return
    var stage = read.take()
    send_str(client_fd, String("$") + String(rec.length) + "\r\n")
    send_all(client_fd, stage)
    send_str(client_fd, String("\r\n"))


def handle_del(client_fd: c_int, mut state: ServerState, key: String) raises:
    """`DEL <key>\\r\\n` → ":1\\r\\n" or ":0\\r\\n". Bytes leak."""
    if key in state.kv:
        _ = state.kv.pop(key)
        send_str(client_fd, String(":1\r\n"))
    else:
        send_str(client_fd, String(":0\r\n"))


# ── Task handlers ───────────────────────────────────────────────────────
def handle_tpush(
    client_fd: c_int,
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    payload_len: Int,
    mut buf: List[UInt8],
    consumed_through: Int,
):
    """`TPUSH <N>\\r\\n<N bytes>` — create a PENDING task. Returns the
    auto-assigned task ID so the caller can later ACK / NACK it."""
    var have_in_buf = len(buf) - consumed_through
    var still_need = payload_len - have_in_buf
    if still_need > 0:
        if not recv_exactly(client_fd, buf, still_need):
            send_str(client_fd, String("-ERR short read\r\n"))
            return

    var offset = _gpu_write(state, dev_base, buf.unsafe_ptr() + consumed_through, payload_len)
    if offset < 0:
        send_str(client_fd, String("-ERR capacity exhausted\r\n"))
        return

    var task_id = state.next_task_id
    state.next_task_id += 1
    state.tasks[task_id] = TaskRecord(offset, payload_len, TASK_PENDING)
    send_str(client_fd, String("+OK ") + String(task_id) + "\r\n")


def handle_claim(
    client_fd: c_int,
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
) raises:
    """`CLAIM\\r\\n` — pick the oldest PENDING task, mark CLAIMED, send
    back "+OK <id> <N>\\r\\n<bytes>\\r\\n". $-1 if none available.

    Strategy: linear scan over `tasks` ordered by ID (Mojo's Dict is
    insertion-ordered for typical sizes; for v0.0.1 that's fine).
    """
    # Find lowest-ID pending task.
    var best_id: Int = -1
    for k in state.tasks.keys():
        var id = Int(k)
        if state.tasks[id].status == TASK_PENDING:
            if best_id < 0 or id < best_id:
                best_id = id

    if best_id < 0:
        send_str(client_fd, String("$-1\r\n"))
        return

    var rec = state.tasks[best_id]
    var read = _gpu_read(state, dev_base, rec.offset, rec.length)
    if not read:
        send_str(client_fd, String("-ERR memcpy device→host failed\r\n"))
        return

    rec.status = TASK_CLAIMED
    state.tasks[best_id] = rec
    var stage = read.take()
    send_str(client_fd, String("+OK ") + String(best_id) + " " + String(rec.length) + "\r\n")
    send_all(client_fd, stage)
    send_str(client_fd, String("\r\n"))


def handle_ack(client_fd: c_int, mut state: ServerState, id_str: String) raises:
    """`ACK <id>\\r\\n` — mark task COMPLETED (drop it from the table)."""
    var id: Int
    try:
        id = atol(id_str)
    except:
        send_str(client_fd, String("-ERR bad task id\r\n"))
        return
    if id in state.tasks:
        _ = state.tasks.pop(id)
        send_str(client_fd, String(":1\r\n"))
    else:
        send_str(client_fd, String(":0\r\n"))


def handle_nack(client_fd: c_int, mut state: ServerState, id_str: String) raises:
    """`NACK <id>\\r\\n` — return a claimed task to PENDING for re-claim."""
    var id: Int
    try:
        id = atol(id_str)
    except:
        send_str(client_fd, String("-ERR bad task id\r\n"))
        return
    if id not in state.tasks:
        send_str(client_fd, String(":0\r\n"))
        return
    var rec = state.tasks[id]
    rec.status = TASK_PENDING
    state.tasks[id] = rec
    send_str(client_fd, String(":1\r\n"))


def handle_tasks(client_fd: c_int, state: ServerState) raises:
    """`TASKS\\r\\n` → "*N\\r\\n" + N lines of "<id> <status>\\r\\n"."""
    send_str(client_fd, String("*") + String(len(state.tasks)) + "\r\n")
    for k in state.tasks.keys():
        var id = Int(k)
        var rec = state.tasks[id]
        var status_name = String("?")
        if   rec.status == TASK_PENDING:   status_name = String("PENDING")
        elif rec.status == TASK_CLAIMED:   status_name = String("CLAIMED")
        elif rec.status == TASK_COMPLETED: status_name = String("COMPLETED")
        elif rec.status == TASK_FAILED:    status_name = String("FAILED")
        send_str(client_fd, String(id) + " " + status_name + " " + String(rec.length) + "\r\n")


def handle_keys(client_fd: c_int, state: ServerState):
    """`KEYS\\r\\n` → "*N\\r\\n" + N lines of "$<klen>\\r\\n<key>\\r\\n"."""
    var n = len(state.kv)
    send_str(client_fd, String("*") + String(n) + "\r\n")
    for k in state.kv.keys():
        var key = String(k)
        send_str(client_fd, String("$") + String(key.byte_length()) + "\r\n" + key + "\r\n")


# ── FIND: substring search across queue + tasks + kv ────────────────────
def _contains_needle(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    """Naive O(n*m) substring search. Fine for v0.0.1 — the GPU-kernel
    version of this lives behind the same protocol verb in v0.0.2."""
    var hn = len(hay)
    var nn = len(needle)
    if nn == 0:
        return True
    if nn > hn:
        return False
    for i in range(hn - nn + 1):
        var matched = True
        for j in range(nn):
            if hay[i + j] != needle[j]:
                matched = False
                break
        if matched:
            return True
    return False


def handle_find(
    client_fd: c_int,
    state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
    needle_len: Int,
    mut buf: List[UInt8],
    consumed_through: Int,
) raises:
    """`FIND <N>\\r\\n<needle>` — return matching items across queue,
    tasks, and KV. Currently host-side: pulls each item back and scans.

    Response format:
        *<total_matches>\\r\\n
        +Q <queue_pos> <length>\\r\\n
        +T <task_id> <length>\\r\\n
        +K <key> <length>\\r\\n
        ...

    The next iteration will move the inner loop into a GPU kernel: one
    thread per item, all scanning in parallel against the device-side
    needle. That's the actual reason for putting the queue in HBM in
    the first place.
    """
    var have_in_buf = len(buf) - consumed_through
    var still_need = needle_len - have_in_buf
    if still_need > 0:
        if not recv_exactly(client_fd, buf, still_need):
            send_str(client_fd, String("-ERR short read\r\n"))
            return
    var needle = List[UInt8]()
    for i in range(consumed_through, consumed_through + needle_len):
        needle.append(buf[i])

    # Collect matches first so we can emit the total count up front.
    var match_lines = List[String]()

    # Pending queue items.
    for i in range(state.q_head_idx, len(state.q_records)):
        var rec = state.q_records[i]
        var read = _gpu_read(state, dev_base, rec.offset, rec.length)
        if read:
            if _contains_needle(read.value(), needle):
                match_lines.append(String("+Q ") + String(i - state.q_head_idx) + " " + String(rec.length) + "\r\n")

    # Tasks (only those still in the table — completed ones are popped).
    for k in state.tasks.keys():
        var id = Int(k)
        var rec = state.tasks[id]
        var read = _gpu_read(state, dev_base, rec.offset, rec.length)
        if read:
            if _contains_needle(read.value(), needle):
                match_lines.append(String("+T ") + String(id) + " " + String(rec.length) + "\r\n")

    # KV entries.
    for k in state.kv.keys():
        var key = String(k)
        var rec = state.kv[key]
        var read = _gpu_read(state, dev_base, rec.offset, rec.length)
        if read:
            if _contains_needle(read.value(), needle):
                match_lines.append(String("+K ") + key + " " + String(rec.length) + "\r\n")

    send_str(client_fd, String("*") + String(len(match_lines)) + "\r\n")
    for line in match_lines:
        send_str(client_fd, line)


# ── Per-connection handler ──────────────────────────────────────────────
def handle_connection(
    client_fd: c_int,
    mut state: ServerState,
    dev_base: UnsafePointer[UInt8, MutAnyOrigin],
) raises:
    """One TCP connection = one command for now.

    Read until we see the first \\r\\n, dispatch on the verb. Some verbs
    consume a payload that follows the request line in the same byte stream.
    """
    var buf = List[UInt8]()
    while True:
        if find_crlf(buf, 0) >= 0:
            break
        var n = recv_some(client_fd, buf, READ_BUFFER_SIZE)
        if n == 0:
            return  # peer closed

    var line_end = find_crlf(buf, 0)
    var line = slice_to_string(buf, 0, line_end)
    var after_line = line_end + 2

    if line.startswith("PUSH "):
        var payload_len: Int
        try:
            payload_len = atol(String(line[byte=5:]))
        except:
            send_str(client_fd, String("-ERR bad PUSH length\r\n"))
            return
        if payload_len < 0 or payload_len > state.capacity:
            send_str(client_fd, String("-ERR PUSH length out of range\r\n"))
            return
        handle_push(client_fd, state, dev_base, payload_len, buf, after_line)

    elif line == "POP":
        handle_pop(client_fd, state, dev_base)

    elif line == "LEN":
        handle_len(client_fd, state)

    elif line == "STATS":
        handle_stats(client_fd, state)

    elif line.startswith("BENCH_BANDWIDTH "):
        var size: Int
        try:
            size = atol(String(line[byte=16:]))
        except:
            send_str(client_fd, String("-ERR bad BENCH_BANDWIDTH size\r\n"))
            return
        handle_bench_bandwidth(client_fd, state, dev_base, size)

    elif line.startswith("SET "):
        # SET <key> <N>
        var rest = String(line[byte=4:])
        var sp = rest.rfind(" ")
        if sp <= 0:
            send_str(client_fd, String("-ERR bad SET syntax\r\n"))
            return
        var key = String(rest[byte=:sp])
        var payload_len: Int
        try:
            payload_len = atol(String(rest[byte=sp + 1:]))
        except:
            send_str(client_fd, String("-ERR bad SET length\r\n"))
            return
        if payload_len < 0 or payload_len > state.capacity:
            send_str(client_fd, String("-ERR SET length out of range\r\n"))
            return
        handle_set(client_fd, state, dev_base, key, payload_len, buf, after_line)

    elif line.startswith("GET "):
        handle_get(client_fd, state, dev_base, String(line[byte=4:]))

    elif line.startswith("DEL "):
        handle_del(client_fd, state, String(line[byte=4:]))

    elif line == "KEYS":
        handle_keys(client_fd, state)

    elif line.startswith("TPUSH "):
        var payload_len: Int
        try:
            payload_len = atol(String(line[byte=6:]))
        except:
            send_str(client_fd, String("-ERR bad TPUSH length\r\n"))
            return
        if payload_len < 0 or payload_len > state.capacity:
            send_str(client_fd, String("-ERR TPUSH length out of range\r\n"))
            return
        handle_tpush(client_fd, state, dev_base, payload_len, buf, after_line)

    elif line == "CLAIM":
        handle_claim(client_fd, state, dev_base)

    elif line.startswith("ACK "):
        handle_ack(client_fd, state, String(line[byte=4:]))

    elif line.startswith("NACK "):
        handle_nack(client_fd, state, String(line[byte=5:]))

    elif line == "TASKS":
        handle_tasks(client_fd, state)

    elif line.startswith("FIND "):
        var needle_len: Int
        try:
            needle_len = atol(String(line[byte=5:]))
        except:
            send_str(client_fd, String("-ERR bad FIND length\r\n"))
            return
        if needle_len < 0 or needle_len > 4096:
            send_str(client_fd, String("-ERR FIND length out of range\r\n"))
            return
        handle_find(client_fd, state, dev_base, needle_len, buf, after_line)

    else:
        send_str(client_fd, String("-ERR unknown command '") + line + "'\r\n")


# ── Demo entry point ────────────────────────────────────────────────────
# Standalone GPU-queue TCP server. Not an entry point in the bundle;
# Phase 2 will expose this through `baldr.Queue` without the TCP layer.
def _demo() raises:
    # Port + capacity from env.
    var port = DEFAULT_PORT
    var port_env = getenv("GPUQ_PORT")
    if port_env.byte_length() > 0:
        port = atol(port_env)
    var capacity_mb = DEFAULT_CAPACITY_MB
    var cap_env = getenv("GPUQ_CAPACITY_MB")
    if cap_env.byte_length() > 0:
        capacity_mb = atol(cap_env)
    var capacity_bytes = capacity_mb * 1024 * 1024

    print("┌──────────────────────────────────────────────────────┐")
    print("│  mojo-gpuq v0.0.1  ·  Apache-2.0  ·  Light of Baldr  │")
    print("└──────────────────────────────────────────────────────┘")
    print("[gpuq] resolving CUDA Driver API via libcuda.so.1...")
    var cuda = OwnedDLHandle("libcuda.so.1")
    var htod = cuda.get_function[HtoDFn]("cuMemcpyHtoD_v2")
    var dtoh = cuda.get_function[DtoHFn]("cuMemcpyDtoH_v2")
    print("[gpuq] CUDA memcpy entrypoints bound")

    print("[gpuq] allocating", capacity_mb, "MiB on GPU device 0...")
    var ctx = DeviceContext()
    var dev_buf = ctx.create_buffer_sync[DType.uint8](capacity_bytes)
    var dev_base = dev_buf.unsafe_ptr().bitcast[UInt8]()
    print("[gpuq] device buffer allocated, base ptr =", Int(dev_base))

    var state = ServerState(capacity_bytes, htod, dtoh)

    # TCP listener.
    var sock = socket_create()
    if Int(sock) < 0:
        print("[fatal] socket() failed")
        return
    _ = socket_reuseaddr(sock)
    var addr = make_sockaddr_in(port)
    if not socket_bind(sock, addr):
        print("[fatal] bind() failed on port", port)
        socket_close(sock)
        return
    if not socket_listen(sock):
        print("[fatal] listen() failed")
        socket_close(sock)
        return

    print("[gpuq] listening on 0.0.0.0:" + String(port))
    print("[gpuq] try:  printf 'STATS\\r\\n' | nc localhost", port)

    while True:
        var client = socket_accept(sock)
        if Int(client) < 0:
            continue
        handle_connection(client, state, dev_base)
        socket_close(client)
