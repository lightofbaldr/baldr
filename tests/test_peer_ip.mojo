"""Client-identity plumbing — Request.peer via getpeername(2).

Verifies the getpeername FFI + error path (empty on an unconnected socket) and
that parse_request threads the kernel-reported peer onto the Request so a rate
limiter can key on the client IP rather than req.path. (Extracting a real
"127.0.0.1" needs a connected socket pair — integration-level, out of unit scope.)
"""

from std.ffi import c_int
from baldr.http import socket_create, socket_peer_ip, socket_close
from baldr.request import parse_request, Request


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def main() raises:
    var total = 0
    var fail = 0

    # getpeername on an unconnected socket -> "" (FFI succeeds, error handled).
    var sock = socket_create()
    total += 1
    if socket_peer_ip(sock) == String(""):
        print("[ok] peer_ip empty on unconnected socket")
    else:
        fail += 1
        print("[FAIL] peer_ip on unconnected socket")
    socket_close(sock)

    # parse_request threads the peer onto Request.
    total += 1
    var req = parse_request(_bytes(String("GET / HTTP/1.1\r\n\r\n")), String("10.1.2.3"))
    if req.peer == String("10.1.2.3"):
        print("[ok] parse_request sets req.peer")
    else:
        fail += 1
        print("[FAIL] req.peer not threaded")

    # Default Request has an empty peer.
    total += 1
    var d = Request()
    if d.peer == String(""):
        print("[ok] default Request peer empty")
    else:
        fail += 1
        print("[FAIL] default peer not empty")

    print("---")
    print(total - fail, "/", total, "passed")
    if fail > 0:
        raise Error("test failures: " + String(fail))
