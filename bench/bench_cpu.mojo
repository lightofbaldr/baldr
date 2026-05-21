"""baldr bench — CPU backend microbenchmarks.

Builds a synthetic corpus and measures:
  - CpuQueue.find_str throughput at 1 MB / 8 MB / 64 MB / 256 MB.
  - CpuQueue.push / pop ops/sec (small payloads, 64 bytes).
  - CpuQueue.set / get ops/sec.

Build:
    pixi run bench-cpu
Run:
    build/bench-cpu

Numbers vary by host. Recorded values in docs/PERF.md come from Spark 2
(NVIDIA DGX Spark, GB10 ARM64, Mojo 1.0.0b2).
"""

from std.time import perf_counter_ns

from baldr.queue.cpu import CpuQueue, Match


def _str_to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def build_corpus(target_bytes: Int) raises -> CpuQueue:
    var q = CpuQueue(capacity=target_bytes * 2)
    var letters = String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    var block = letters + letters[byte=0:12]   # 64 bytes
    var sentinel = block[byte=0:48] + "BALDR_MARKER"
    var n_blocks = target_bytes // 64
    var i = 0
    while i < n_blocks:
        var s: String
        if i % 100 == 99:
            s = String(sentinel)
        else:
            s = String(block)
        _ = q.push(_str_to_bytes(s))
        i += 1
    return q^


def bench_scan(size_bytes: Int, trials: Int) raises:
    var q = build_corpus(size_bytes)
    var actual = q.tail

    # Warmup.
    _ = q.find_str(String("BALDR_MARKER"))

    var matches = q.find_str(String("BALDR_MARKER"))
    var t0 = perf_counter_ns()
    for _ in range(trials):
        matches = q.find_str(String("BALDR_MARKER"))
    var t1 = perf_counter_ns()

    var total_bytes = actual * trials
    var ns = Int(t1 - t0)
    # Throughput in MB/s. ns / 1000 → us. total_bytes / us = MB/s.
    var mb_per_s = (total_bytes // 1024 // 1024 * 1000_000_000) // ns
    print("scan ", actual // 1024, "KiB × ", trials, "trials →",
          mb_per_s, "MB/s,",
          len(matches), "matches/trial")


def bench_miss_scan(size_bytes: Int, trials: Int) raises:
    """Same as bench_scan but with a needle that never matches — pure
    SIMD broadcast-and-compare path, no scalar verify."""
    var q = build_corpus(size_bytes)
    var actual = q.tail

    _ = q.find_str(String("ZZZZZ_NOPE"))

    var t0 = perf_counter_ns()
    for _ in range(trials):
        _ = q.find_str(String("ZZZZZ_NOPE"))
    var t1 = perf_counter_ns()

    var total_bytes = actual * trials
    var ns = Int(t1 - t0)
    var mb_per_s = (total_bytes // 1024 // 1024 * 1000_000_000) // ns
    print("scan ", actual // 1024, "KiB × ", trials, "trials (miss) →",
          mb_per_s, "MB/s")


def bench_queue_push_pop(ops: Int) raises:
    var q = CpuQueue(capacity=ops * 128)
    var payload = String("the quick brown fox jumps over the lazy dog ABCDEFGHIJKLMNOP")  # 60 bytes

    var t0 = perf_counter_ns()
    for _ in range(ops):
        _ = q.push(_str_to_bytes(payload))
    var t_push = perf_counter_ns()
    for _ in range(ops):
        _ = q.pop()
    var t_pop = perf_counter_ns()

    var push_us = (t_push - t0) // 1000
    var pop_us = (t_pop - t_push) // 1000
    var push_ops_per_s = (ops * 1_000_000) // Int(push_us if push_us > 0 else 1)
    var pop_ops_per_s  = (ops * 1_000_000) // Int(pop_us  if pop_us  > 0 else 1)
    print("queue push", ops, "× 60 B →", push_ops_per_s, "ops/s (", push_us, "us total)")
    print("queue pop ", ops, "× 60 B →", pop_ops_per_s, "ops/s (", pop_us, "us total)")


def bench_kv(ops: Int) raises:
    var q = CpuQueue(capacity=ops * 128)
    var payload = String("the quick brown fox jumps over the lazy dog ABCDEFGHIJKLMNOP")

    var t0 = perf_counter_ns()
    for i in range(ops):
        var key = String("k") + String(i)
        q.set(key, _str_to_bytes(payload))
    var t_set = perf_counter_ns()
    for i in range(ops):
        var key = String("k") + String(i)
        _ = q.get(key)
    var t_get = perf_counter_ns()

    var set_us = (t_set - t0) // 1000
    var get_us = (t_get - t_set) // 1000
    var set_ops_per_s = (ops * 1_000_000) // Int(set_us if set_us > 0 else 1)
    var get_ops_per_s = (ops * 1_000_000) // Int(get_us if get_us > 0 else 1)
    print("kv set", ops, "× 60 B →", set_ops_per_s, "ops/s (", set_us, "us total)")
    print("kv get", ops, "× 60 B →", get_ops_per_s, "ops/s (", get_us, "us total)")


def main() raises:
    print("=== baldr CPU bench ===")
    print("--- substring scan (hit-dense, 1 sentinel per 100 blocks) ---")
    bench_scan(  1 * 1024 * 1024, 10)
    bench_scan(  8 * 1024 * 1024, 10)
    bench_scan( 64 * 1024 * 1024, 5)
    bench_scan(256 * 1024 * 1024, 2)

    print("--- substring scan (miss-only, no scalar verify) ---")
    bench_miss_scan( 8 * 1024 * 1024, 10)
    bench_miss_scan(64 * 1024 * 1024, 5)

    print("--- queue push/pop ---")
    bench_queue_push_pop(100_000)

    print("--- kv set/get ---")
    bench_kv(100_000)
