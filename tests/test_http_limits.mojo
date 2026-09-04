"""Hardening for http read_request — SO_RCVTIMEO slowloris guard.

A full slow/malformed-input socket harness is heavier than the unit suite
warrants; this verifies the SO_RCVTIMEO FFI actually succeeds on a real fd
(the core of the slowloris guard). The header/body size caps are enforced by
construction in read_request (bounded accumulation; it returns empty and the
caller closes once MAX_HEADER_BYTES or max_body_bytes is exceeded).
"""

from std.ffi import c_int
from baldr.http import socket_create, socket_recv_timeout, socket_close


def main() raises:
    var total = 0
    var fail = 0

    var sock = socket_create()
    total += 1
    if Int(sock) >= 0:
        print("[ok] socket created")
    else:
        fail += 1
        print("[FAIL] socket created")

    total += 1
    if socket_recv_timeout(sock, 1):
        print("[ok] SO_RCVTIMEO set on real fd (slowloris guard)")
    else:
        fail += 1
        print("[FAIL] SO_RCVTIMEO setsockopt failed")

    socket_close(sock)
    print("---")
    print(total - fail, "/", total, "passed")
    if fail > 0:
        raise Error("test failures: " + String(fail))
