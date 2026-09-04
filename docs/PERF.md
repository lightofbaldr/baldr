# baldr — performance notes

> Numbers from Spark 2 (NVIDIA DGX Spark · GB10 ARM64, unified memory),
> Mojo 1.0.0b2, single-threaded, no other concurrent workload.
> Run yourself: `pixi run bench-cpu`.

## CPU substring scan

`CpuQueue.find_str(needle)` uses `SIMD[DType.uint8, 32]` two-stage
scanning: broadcast `needle[0]` across the vector, compare, scalar
verify on hits. Same source compiles to AVX2 on x86-64 and to paired
Neon ops on ARM64.

| Corpus | Pattern | Throughput | Notes |
|---|---|---|---|
| 1 MB | hit-dense | 1010 MB/s | 163 matches |
| 8 MB | hit-dense | 1057 MB/s | 1310 matches |
| 64 MB | hit-dense | 1051 MB/s | 10485 matches |
| 256 MB | hit-dense | 1030 MB/s | 41943 matches |
| 8 MB | miss-only | 1091 MB/s | no scalar verify |
| 64 MB | miss-only | 1086 MB/s | no scalar verify |

Throughput is stable across sizes (cache thrashing isn't the
bottleneck at these scales — the loop is SIMD-bound on the Neon
units). Hit-density costs ~3–4 % vs the miss-only path; the scalar
verify only fires on actual `needle[0]` matches, which is the design
goal of the two-stage pattern.

## CPU queue / KV

60-byte payloads, single-threaded, 100k operations per phase:

| Operation | Throughput | Total time |
|---|---|---|
| `CpuQueue.push` | 5.0 M ops/s | 19.9 ms |
| `CpuQueue.pop`  | 9.7 M ops/s | 10.3 ms |
| `CpuQueue.set`  | 4.0 M ops/s | 25.3 ms |
| `CpuQueue.get`  | 5.6 M ops/s | 17.7 ms |

`push` is slower than `pop` because each push allocates from the
append-only data buffer and registers a `CpuKVRecord`; pop is a single
index increment + slice copy. The KV path has slightly more overhead
than the queue because it hits the `Dict[String, …]` hash table.

## HTTP roundtrip

`examples/hello` on port 8090, `GET /api/health` returning a 35-byte
JSON body:

| Driver | Time / request | Throughput |
|---|---|---|
| In-server handler time (logged) | ~7 µs | — |
| Sequential `curl` from localhost | 2.67 ms | 374 req/s |
| Sequential `curl` × 1000 | 2.94 ms | 340 req/s |

The handler itself runs in ~7 µs (parse_request + dispatch +
security-headers + format the response). The 1000× curl loop measures
fork/exec overhead per request, not the server's capacity. A keep-alive
load generator would show much higher throughput — v0.1 closes the
socket on every response (`Connection: close`); keep-alive is in scope
for v0.2.

## GPU backend

The vendored `baldr.queue.gpu` backend is the same code as
`mojo-gpuq`; previously-measured peak throughput on Spark 2's GB10
(via `cuMemcpyHtoD_v2` from `cuda.so`) was **~12 GB/s push** and
similar pull on 64 KiB payloads. Substring search across GPU memory
isn't a CUDA-kernel yet (host-side scan over device-pulled bytes);
the GB10's HBM is the bottleneck once that lands. SPEC §6 frames the
CPU/GPU choice: CPU is for the "works on my laptop" path, GPU is for
DGX-class hosts that want to keep payloads off the host bus.

## Test suite

`pixi run test` builds and runs six drivers. Wall-clock on Spark 2:

- 36 / 36 `test_template`
- 43 / 43 `test_json`
- 29 / 29 `test_api`
- 33 / 33 `test_queue_cpu` (including the 4 SIMD-scan correctness cases)
- 30 / 30 `test_middleware`
- 6 / 6 `test_imports`

**Total: 177 / 177 assertions** in well under a minute end-to-end
(most of the time is `mojo build`, not the test runs).

## Reproducing

```bash
pixi install
pixi run bench-cpu          # the table above
pixi run example-hello &
build/example-hello &
( time for i in $(seq 1 1000); do curl -s -o /dev/null http://127.0.0.1:8090/api/health; done )
```

The bench is deterministic: same corpus shape every run, no clock or
network in the hot path.
