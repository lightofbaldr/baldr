"""Tiny TCP client for mojo-gpuq, embedded in the stack demo.

Lives in the same binary as the web server. Each call opens a fresh
connection to the gpuq-server (port 6379 by default) — exactly how the
v0.0.1 protocol expects clients to talk.

This module is also a real demonstration of the stack: the demo server
is *itself* a client of mojo-gpuq, so the chat backend round-trips
through GPU memory on Spark 2's GB10.
"""

from std.ffi import c_int, c_size_t, external_call
from std.memory import UnsafePointer
from std.os.env import getenv


comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1


def _gpuq_host() -> String:
    var h = getenv("GPUQ_HOST")
    if h.byte_length() > 0:
        return h^
    return String("127.0.0.1")


def _gpuq_port() -> Int:
    var p = getenv("GPUQ_PORT")
    if p.byte_length() > 0:
        try:
            return atol(p)
        except:
            pass
    return 6379


def _parse_ip_a(ip: String) -> List[UInt8]:
    """Parse a dotted-quad IPv4. Returns 4-byte big-endian octets."""
    var out = List[UInt8]()
    var parts = ip.split(".")
    for k in range(4):
        if k < len(parts):
            try:
                out.append(UInt8(atol(String(parts[k]))))
            except:
                out.append(UInt8(0))
        else:
            out.append(UInt8(0))
    return out^


def _connect(host: String, port: Int) -> c_int:
    """Open a TCP connection to host:port. Returns fd or -1."""
    var fd = external_call["socket", c_int, c_int, c_int, c_int](
        AF_INET, SOCK_STREAM, c_int(0)
    )
    if Int(fd) < 0:
        return fd
    var addr = List[UInt8](capacity=16)
    for _ in range(16):
        addr.append(0)
    addr[0] = UInt8(2)
    addr[2] = UInt8((port >> 8) & 0xFF)
    addr[3] = UInt8(port & 0xFF)
    var ip = _parse_ip_a(host)
    addr[4] = ip[0]; addr[5] = ip[1]; addr[6] = ip[2]; addr[7] = ip[3]
    var rc = external_call[
        "connect", c_int,
        c_int, UnsafePointer[UInt8, origin_of(addr)], c_int,
    ](fd, addr.unsafe_ptr(), c_int(16))
    if Int(rc) != 0:
        _ = external_call["close", c_int, c_int](fd)
        return c_int(-1)
    return fd


def _send_all(fd: c_int, mut data: List[UInt8]):
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


def _send_str(fd: c_int, s: String):
    var b = s.as_bytes()
    var lst = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        lst.append(b[i])
    _send_all(fd, lst)


def _recv_all(fd: c_int) -> List[UInt8]:
    """Read until peer closes. Used after we send our command + half-close."""
    # We don't actually half-close here (Mojo stdlib hides shutdown(2));
    # gpuq replies and closes the connection from its side, so we just
    # loop on recv until 0.
    var out = List[UInt8]()
    var buf = List[UInt8](capacity=65536)
    for _ in range(65536):
        buf.append(0)
    while True:
        var n = external_call[
            "recv", c_size_t,
            c_int, UnsafePointer[UInt8, origin_of(buf)], c_size_t, c_int,
        ](fd, buf.unsafe_ptr(), c_size_t(65536), c_int(0))
        var got = Int(n)
        if got <= 0:
            break
        for i in range(got):
            out.append(buf[i])
    return out^


# ── Higher-level commands ───────────────────────────────────────────────

def _round_trip_text(cmd: String) -> String:
    """Send a complete command (already CRLF-terminated) and return the
    decoded response as a String. Caller handles parsing."""
    var fd = _connect(_gpuq_host(), _gpuq_port())
    if Int(fd) < 0:
        return String()
    _send_str(fd, cmd)
    var raw = _recv_all(fd)
    _ = external_call["close", c_int, c_int](fd)
    return String(unsafe_from_utf8=raw[:])


def _round_trip_bytes(mut cmd: List[UInt8]) -> List[UInt8]:
    """Same as _round_trip_text but for raw byte commands (PUSH/SET/TPUSH
    need binary payloads after the CRLF)."""
    var fd = _connect(_gpuq_host(), _gpuq_port())
    if Int(fd) < 0:
        return List[UInt8]()
    _send_all(fd, cmd)
    var raw = _recv_all(fd)
    _ = external_call["close", c_int, c_int](fd)
    return raw^


def _build_push_command(verb: String, payload: String) -> List[UInt8]:
    """Build a `VERB N\\r\\n<bytes>` request as a byte buffer."""
    var pb = payload.as_bytes()
    var header = verb + " " + String(len(pb)) + "\r\n"
    var hb = header.as_bytes()
    var out = List[UInt8](capacity=len(hb) + len(pb))
    for i in range(len(hb)):
        out.append(hb[i])
    for i in range(len(pb)):
        out.append(pb[i])
    return out^


def gpuq_tpush(payload: String) -> Int:
    """Create a PENDING task in mojo-gpuq. Returns the task ID, or -1 on error."""
    var cmd = _build_push_command(String("TPUSH"), payload)
    var resp = _round_trip_bytes(cmd)
    var s = String(unsafe_from_utf8=resp[:])
    if not s.startswith("+OK "):
        return -1
    # "+OK <id>\r\n"
    var crlf = s.find("\r\n")
    if crlf < 0:
        return -1
    try:
        return atol(String(s[byte=4:crlf]))
    except:
        return -1


def gpuq_tasks() -> List[String]:
    """Return all task records as ["1 PENDING 14", "2 CLAIMED 13", ...]."""
    var s = _round_trip_text(String("TASKS\r\n"))
    var out = List[String]()
    var first_nl = s.find("\r\n")
    if first_nl < 0:
        return out^
    var header = String(s[byte=:first_nl])
    if not header.startswith("*"):
        return out^
    var n: Int
    try:
        n = atol(String(header[byte=1:]))
    except:
        return out^
    var rest = String(s[byte=first_nl + 2:])
    for _ in range(n):
        var nl = rest.find("\r\n")
        if nl < 0:
            break
        out.append(String(rest[byte=:nl]))
        rest = String(rest[byte=nl + 2:])
    return out^


def gpuq_claim() -> String:
    """Claim the oldest PENDING task. Returns "id|payload" or "" if empty."""
    var cmd = _str_to_bytes(String("CLAIM\r\n"))
    var raw = _round_trip_bytes(cmd)
    var s = String(unsafe_from_utf8=raw[:])
    if s.startswith("$-1"):
        return String()
    if not s.startswith("+OK "):
        return String()
    var nl = s.find("\r\n")
    if nl < 0:
        return String()
    var header = String(s[byte=4:nl])
    # header == "<id> <length>"
    var sp = header.find(" ")
    if sp < 0:
        return String()
    var id_str = String(header[byte=:sp])
    var len_str = String(header[byte=sp + 1:])
    var payload_len: Int
    try:
        payload_len = atol(len_str)
    except:
        return String()
    var body_start = nl + 2
    if body_start + payload_len > s.byte_length():
        return String()
    var payload = String(s[byte=body_start:body_start + payload_len])
    return id_str + "|" + payload


def gpuq_ack(task_id: Int) -> Bool:
    var s = _round_trip_text(String("ACK ") + String(task_id) + "\r\n")
    return s.startswith(":1")


def gpuq_stats() -> String:
    """Return the raw STATS line ("+OK capacity=N tail=N queue_count=N ...")."""
    var s = _round_trip_text(String("STATS\r\n"))
    var nl = s.find("\r\n")
    if nl < 0:
        return String()
    return String(s[byte=:nl])


def gpuq_bench_bandwidth(size_bytes: Int) -> String:
    """Trigger one round of H2D + D2H benchmark on the GPU.

    Returns the raw "+OK bytes=N h2d_ns=N d2h_ns=N" line, or empty if
    gpuq-server didn't respond. The caller parses out the fields.
    """
    var cmd = String("BENCH_BANDWIDTH ") + String(size_bytes) + "\r\n"
    var s = _round_trip_text(cmd)
    var nl = s.find("\r\n")
    if nl < 0:
        return String()
    return String(s[byte=:nl])


def _str_to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^
