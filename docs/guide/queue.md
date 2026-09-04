# The GPU Queue

baldr bundles a small in-process store — a FIFO **queue**, a **key/value** map, and a **task** queue with claim/ack semantics — behind one type, `Queue`. Its distinguishing trick: the same API can keep its payloads in CPU memory *or* in **GPU device memory**, chosen at startup. No Redis, no separate process; it lives inside your binary.

!!! warning "Experimental — v0.1"
    The queue is single-process and single-threaded, with no internal locking. If you serve from multiple handler threads, guard your own access. It's genuinely useful for in-process buffering and GPU-resident scratch, but it is not (yet) a networked broker. Treat it as a building block, not a drop-in Redis.

## Picking a backend

```mojo
from baldr.queue.api import Queue

var q = Queue.local()                  # backend chosen by the BALDR_QUEUE_BACKEND env var
var q = Queue.cpu_backend()            # force CPU memory
var q = Queue.gpu_backend()            # force GPU — raises if libcuda/device is unavailable
```

Each takes an optional `capacity_bytes` (default 1 GiB). `Queue.local()` reads `BALDR_QUEUE_BACKEND` so the same binary runs CPU-only on your laptop and GPU-backed on the DGX with no code change. `backend_name()` tells you which you got.

!!! note "What 'GPU-resident' means"
    With the GPU backend, payloads live in a `DeviceBuffer`: `push`/`set` copy bytes host→device (`cuMemcpyHtoD`), `pop`/`get` copy the matching window back. The queue's *data* sits on the device — useful when the next stage is a MAX kernel that already runs there, so you skip a host round-trip. It uses MAX's device APIs, not hand-written CUDA.

## The queue surface (FIFO)

Payloads are bytes — `List[UInt8]` — so anything serializes into them:

```mojo
var id = q.push(some_bytes^)     # -> Int position; returns the item's id
var item = q.pop()               # -> List[UInt8], FIFO order (raises if empty)
var n = q.len()                  # pending items
var cap = q.capacity()           # capacity in bytes
```

## The key/value surface

```mojo
q.set("user:1", payload^)      # store
var v = q.get("user:1")        # fetch (raises if missing)
var here = q.has("user:1")     # Bool
q.delete("user:1")
var count = q.kv_count()
```

## The task surface (claim / ack / nack)

For work you want *exactly one* worker to process, use the task methods. `tpush` enqueues, `claim` hands the next task to a worker, and the worker `ack`s on success or `nack`s to requeue:

```mojo
var tid = q.tpush(job_bytes^)          # enqueue a task -> task id
var next = q.claim()                   # -> task id now owned by this worker
var payload = q.task_payload(next)     # the job's bytes
# ... do the work ...
q.ack(next)                            # done  (or q.nack(next) to requeue)
var st = q.task_status(tid)            # TASK_PENDING / CLAIMED / COMPLETED / FAILED
```

## Byte search

Both backends can scan stored payloads for a substring:

```mojo
var hits = q.find_str("error")     # -> List[Match]
var hits = q.find(needle_bytes)            # same, raw bytes
```

## Where it fits

The queue shines for **in-process pipelines**: a handler pushes a job, a background loop claims and processes it, results land in the KV map — all without leaving the binary or serializing over a socket. On a GPU box, keeping the payloads device-resident means the data is already where your compute is.

!!! note "Bytes in, bytes out"
    Every method speaks `List[UInt8]`, so you serialize your own structures (JSON via [`dumps`](../reference/json.md), or a packed binary). A typed layer over the byte store is roadmap; for now a thin `to_bytes` / `from_bytes` helper per payload type keeps call sites clean.

Next: **[Deploy →](../deploy.md)** ships the whole thing — binary plus static dir — in a `FROM scratch` image.
