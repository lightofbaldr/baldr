"""Real-process tests for prefork supervision and graceful shutdown."""

from std.ffi import c_int, external_call
from std.os import makedirs
from std.pathlib import Path
from std.time import perf_counter_ns, sleep

from baldr.app import App, DispatchHandler
from baldr.http import (
    make_sockaddr_in,
    process_exit,
    process_execv,
    process_fork,
    process_getpid,
    process_kill,
    process_waitpid,
    process_waitpid_nohang,
    recv_available,
    SIGNAL_INT,
    SIGNAL_KILL,
    SIGNAL_TERM,
    socket_close,
    socket_create,
    write_all,
)
from baldr.lifecycle import LifecycleHooks
from baldr.request import Request
from baldr.response import Response


comptime MODE_ECHO = 0
comptime MODE_SLOW = 1
comptime MODE_DIE_ROUTE = 2
comptime MODE_DIE_ALWAYS = 3


def _mark(path: String) raises:
    Path(path).write_bytes(String("1\n").as_bytes())


@fieldwise_init
struct MarkerLifecycle(LifecycleHooks, Copyable, Movable):
    var root: String

    def on_startup(mut self) raises:
        _mark(self.root + "/started")

    def on_shutdown(mut self) raises:
        _mark(self.root + "/stopped")


@fieldwise_init
struct TestHandler(DispatchHandler, Copyable, Movable):
    var mode: Int
    var root: String

    def __call__(mut self, req: Request) raises -> Response:
        if self.mode == MODE_DIE_ALWAYS:
            process_exit(1)
            return Response.text("unreachable\n")
        if self.mode == MODE_DIE_ROUTE and req.path == "/die":
            process_exit(1)
            return Response.text("unreachable\n")
        if self.mode == MODE_SLOW and req.path == "/slow":
            _mark(self.root + "/request-started")
            sleep(1)
            return Response.text("slow complete\n")
        return Response.text("ok\n")


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int

    def __init__(out self):
        self.total = 0
        self.failures = 0

    def check(mut self, label: String, condition: Bool):
        self.total += 1
        if condition:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)

    def summary(self):
        print("---")
        print(self.total - self.failures, "/", self.total, "passed")


def _exit_code(status: c_int) -> Int:
    var raw = Int(status)
    if (raw & 0x7F) == 0:
        return (raw & 0xFF00) >> 8
    return 128 + (raw & 0x7F)


def _connect(port: Int) -> c_int:
    var sock = socket_create()
    if Int(sock) < 0:
        return sock
    var addr = make_sockaddr_in(port)
    addr[4] = 127
    var rc = external_call[
        "connect", c_int,
        c_int, Pointer[UInt8, origin_of(addr)], c_int,
    ](sock, addr.unsafe_ptr(), c_int(16))
    if Int(rc) != 0:
        socket_close(sock)
        return c_int(-1)
    return sock


def _send_request(fd: c_int, path: String):
    var text = String("GET ") + path + " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    var source = text.as_bytes()
    var data = List[UInt8](capacity=len(source))
    for i in range(len(source)):
        data.append(source[i])
    write_all(fd, data)


def _read_until(fd: c_int, needle: String, timeout_ms: Int) -> String:
    var out = String()
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    while perf_counter_ns() < deadline:
        var part = recv_available(fd, 65536)
        for i in range(len(part)):
            out += chr(Int(part[i]))
        if out.find(needle) >= 0:
            break
        sleep(0.02)
    return out^


def _request(port: Int, path: String, needle: String, timeout_ms: Int = 2000) -> String:
    var fd = _connect(port)
    if Int(fd) < 0:
        return String()
    _send_request(fd, path)
    var response = _read_until(fd, needle, timeout_ms)
    socket_close(fd)
    return response^


def _wait_ready(port: Int, timeout_ms: Int = 4000) -> Bool:
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    while perf_counter_ns() < deadline:
        var fd = _connect(port)
        if Int(fd) >= 0:
            socket_close(fd)
            return True
        sleep(0.05)
    return False


def _wait_file(path: String, timeout_ms: Int = 3000) -> Bool:
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    while perf_counter_ns() < deadline:
        if Path(path).is_file():
            return True
        sleep(0.02)
    return False


def _children(pid: Int) raises -> List[Int]:
    var path = Path("/proc/" + String(pid) + "/task/" + String(pid) + "/children")
    var children = List[Int]()
    if not path.is_file():
        return children^
    var text = path.read_text().strip()
    if text.byte_length() == 0:
        return children^
    for part in text.split(" "):
        var value = String(part).strip()
        if value.byte_length() > 0:
            children.append(Int(value))
    return children^


def _wait_children(pid: Int, count: Int, timeout_ms: Int = 4000) raises -> List[Int]:
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    while perf_counter_ns() < deadline:
        var current = _children(pid)
        if len(current) == count:
            return current^
        sleep(0.05)
    return _children(pid)


def _thread_count(pid: Int) raises -> Int:
    var task_dir = Path("/proc/" + String(pid) + "/task")
    if not task_dir.is_dir():
        return 0
    return len(task_dir.listdir())


def _has_new_pid(before: List[Int], after: List[Int]) -> Bool:
    for i in range(len(after)):
        var found = False
        for j in range(len(before)):
            if after[i] == before[j]:
                found = True
                break
        if not found:
            return True
    return False


def _all_gone(pids: List[Int]) -> Bool:
    for i in range(len(pids)):
        if Path("/proc/" + String(pids[i])).exists():
            return False
    return True


def _wait_exit(pid: Int, timeout_ms: Int, mut status: c_int) -> Bool:
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    while perf_counter_ns() < deadline:
        var got = Int(process_waitpid_nohang(pid, status))
        if got == pid:
            return True
        if got < 0:
            return False
        sleep(0.05)
    return False


def _force_stop(pid: Int, mut status: c_int) raises:
    if Path("/proc/" + String(pid)).exists():
        var workers = _children(pid)
        for i in range(len(workers)):
            _ = process_kill(workers[i], SIGNAL_KILL)
        _ = process_kill(pid, SIGNAL_KILL)
        _ = process_waitpid(pid, status)


def _start_pool(port: Int, root: String, mode: Int, workers: Int, grace_secs: Int) -> Int:
    var pid = Int(process_fork())
    if pid != 0:
        return pid
    var app = App(lifecycle=MarkerLifecycle(root))
    try:
        app.run(TestHandler(mode, root), port=port, workers=workers, grace_secs=grace_secs)
        process_exit(0)
    except:
        process_exit(1)
    return -1


def _start_fresh_pool(port: Int, root: String) -> Int:
    var pid = Int(process_fork())
    if pid != 0:
        return pid
    var args = List[String](capacity=3)
    args.append(String("build/test_supervision_pool_main"))
    args.append(String(port))
    args.append(root)
    _ = process_execv(args)
    process_exit(127)
    return -1


def _fresh_process_stop(root: String, port: Int) raises -> Bool:
    var started_ns = perf_counter_ns()
    var case_root = root + "/fresh-process"
    makedirs(Path(case_root), exist_ok=True)
    var pool = _start_fresh_pool(port, case_root)
    var status: c_int = 0
    var ready = _wait_ready(port)
    var workers = _wait_children(pool, 2)
    var threads = _thread_count(pool)
    var signalled = process_kill(pool, SIGNAL_TERM)
    var exited = _wait_exit(pool, 5000, status)
    var stopped = Path(case_root + "/stopped").is_file()
    var gone = _all_gone(workers)
    var ok = ready and len(workers) == 2 and threads > 1 and signalled \
        and exited and _exit_code(status) == 0 and stopped and gone
    if not exited:
        _force_stop(pool, status)
    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000
    print("[timing] fresh-process multithreaded stop:", elapsed_ms, "ms; threads:", threads)
    if not ok:
        print("[detail] fresh ready/workers/threads/signal/exit/code/stopped/gone:", ready, len(workers), threads, signalled, exited, _exit_code(status), stopped, gone)
    return ok


def _graceful_stop(root: String, port: Int) raises -> Bool:
    var started_ns = perf_counter_ns()
    var pool_root = root + "/graceful-pool"
    makedirs(Path(pool_root), exist_ok=True)
    var pool = _start_pool(port, pool_root, MODE_ECHO, 2, 2)
    var status: c_int = 0
    var ready = _wait_ready(port)
    var workers = _wait_children(pool, 2)
    var signalled = process_kill(pool, SIGNAL_TERM)
    var exited = _wait_exit(pool, 5000, status)
    var pooled_ok = ready and len(workers) == 2 and signalled and exited \
        and _exit_code(status) == 0 and Path(pool_root + "/stopped").is_file() \
        and _all_gone(workers)
    if not exited:
        _force_stop(pool, status)

    # The same self-pipe polling must work without a supervisor.
    var single_root = root + "/graceful-single"
    makedirs(Path(single_root), exist_ok=True)
    var single = _start_pool(port + 1, single_root, MODE_ECHO, 1, 2)
    var single_status: c_int = 0
    var single_ready = _wait_ready(port + 1)
    var single_signalled = process_kill(single, SIGNAL_INT)
    var single_exited = _wait_exit(single, 4000, single_status)
    var single_ok = single_ready and single_signalled and single_exited \
        and _exit_code(single_status) == 0 and Path(single_root + "/stopped").is_file()
    if not single_exited:
        _force_stop(single, single_status)

    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000
    print("[timing] graceful stop (pool + single):", elapsed_ms, "ms")
    if not pooled_ok:
        print("[detail] pool ready/workers/signal/exit/code/stopped/gone:", ready, len(workers), signalled, exited, _exit_code(status), Path(pool_root + "/stopped").is_file(), _all_gone(workers))
    if not single_ok:
        print("[detail] single ready/signal/exit/code/stopped:", single_ready, single_signalled, single_exited, _exit_code(single_status), Path(single_root + "/stopped").is_file())
    return pooled_ok and single_ok


def _drain(root: String, port: Int) raises -> Bool:
    var started_ns = perf_counter_ns()
    var case_root = root + "/drain"
    makedirs(Path(case_root), exist_ok=True)
    var pool = _start_pool(port, case_root, MODE_SLOW, 2, 3)
    var status: c_int = 0
    var ready = _wait_ready(port)
    var fd = _connect(port)
    var connected = Int(fd) >= 0
    if connected:
        _send_request(fd, "/slow")
    var entered = _wait_file(case_root + "/request-started")
    var signalled = process_kill(pool, SIGNAL_TERM)
    var response = _read_until(fd, "slow complete\n", 4000) if connected else String()
    if connected:
        socket_close(fd)
    var exited = _wait_exit(pool, 6000, status)
    var complete = response.find("Content-Length: 14") >= 0 \
        and response.find("\r\n\r\nslow complete\n") >= 0
    var ok = ready and connected and entered and signalled and complete \
        and exited and _exit_code(status) == 0 and Path(case_root + "/stopped").is_file()
    if not exited:
        _force_stop(pool, status)
    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000
    print("[timing] drain in-flight request:", elapsed_ms, "ms")
    if not ok:
        print("[detail] ready/connected/entered/signal/complete/exit/code/stopped:", ready, connected, entered, signalled, complete, exited, _exit_code(status), Path(case_root + "/stopped").is_file())
    return ok


def _respawn(root: String, port: Int) raises -> Bool:
    var started_ns = perf_counter_ns()
    var case_root = root + "/respawn"
    makedirs(Path(case_root), exist_ok=True)
    var pool = _start_pool(port, case_root, MODE_DIE_ROUTE, 2, 2)
    var status: c_int = 0
    var ready = _wait_ready(port)
    var before = _wait_children(pool, 2)
    _ = _request(port, "/die", "never", 300)
    var after = List[Int]()
    var deadline = perf_counter_ns() + 5000 * 1_000_000
    while perf_counter_ns() < deadline:
        after = _children(pool)
        if len(after) == 2 and _has_new_pid(before, after):
            break
        sleep(0.05)
    var response = _request(port, "/", "ok", 2000)
    var signalled = process_kill(pool, SIGNAL_TERM)
    var exited = _wait_exit(pool, 5000, status)
    var ok = ready and len(before) == 2 and len(after) == 2 and _has_new_pid(before, after) \
        and response.find("ok\n") >= 0 and signalled and exited and _exit_code(status) == 0
    if not exited:
        _force_stop(pool, status)
    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000
    print("[timing] worker respawn:", elapsed_ms, "ms")
    if not ok:
        print("[detail] ready/before/after/new/served/signal/exit/code:", ready, len(before), len(after), _has_new_pid(before, after), response.find("ok\n") >= 0, signalled, exited, _exit_code(status))
    return ok


def _crash_loop(root: String, port: Int) raises -> Bool:
    var started_ns = perf_counter_ns()
    var case_root = root + "/crash-loop"
    makedirs(Path(case_root), exist_ok=True)
    var pool = _start_pool(port, case_root, MODE_DIE_ALWAYS, 2, 1)
    var status: c_int = 0
    var ready = _wait_ready(port)
    var deadline = perf_counter_ns() + 14_000_000_000
    var exited = False
    while perf_counter_ns() < deadline:
        var got = Int(process_waitpid_nohang(pool, status))
        if got == pool:
            exited = True
            break
        var fd = _connect(port)
        if Int(fd) >= 0:
            _send_request(fd, "/")
            sleep(0.05)
            socket_close(fd)
        sleep(0.05)
    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000
    var ok = ready and exited and _exit_code(status) != 0 and elapsed_ms < 15_000 \
        and Path(case_root + "/stopped").is_file()
    if not exited:
        _force_stop(pool, status)
    print("[timing] crash-loop cutoff:", elapsed_ms, "ms")
    if not ok:
        print("[detail] ready/exit/code/under15s/stopped:", ready, exited, _exit_code(status), elapsed_ms < 15_000, Path(case_root + "/stopped").is_file())
    return ok


def main() raises:
    var runner = Runner()
    var pid = Int(process_getpid())
    var root = String("build/supervision_") + String(pid) + "_" + String(perf_counter_ns())
    makedirs(Path(root), exist_ok=True)
    var base_port = 30_000 + (pid % 15_000)

    runner.check("fresh multithreaded parent exits zero and reaps workers", _fresh_process_stop(root, base_port))
    runner.check("graceful stop exits zero and reaps workers", _graceful_stop(root, base_port + 1))
    runner.check("SIGTERM drains the in-flight response", _drain(root, base_port + 3))
    runner.check("a crashed worker is respawned and serves again", _respawn(root, base_port + 4))
    runner.check("five rapid respawns trigger nonzero crash-loop shutdown", _crash_loop(root, base_port + 5))
    runner.summary()
    if runner.failures > 0:
        raise Error("supervision test failures: " + String(runner.failures))
