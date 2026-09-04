"""Hardening for safe_join — symlink canonicalization + control-byte rejection.

Creates real symlink fixtures under /tmp via libc FFI so the test exercises the
actual realpath(3) confinement, not just lexical '..' collapsing.
"""

from std.ffi import external_call

from baldr.serve import safe_join


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int
    def __init__(out self):
        self.total = 0
        self.failures = 0
    def check(mut self, label: String, cond: Bool):
        self.total += 1
        if cond:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)
    def summary(self) raises:
        print("---")
        print(self.total - self.failures, "/", self.total, "passed")
        if self.failures > 0:
            raise Error("test failures: " + String(self.failures))


def _cstr(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b) + 1)
    for i in range(len(b)):
        out.append(b[i])
    out.append(0)
    return out^


def _unlink(path: String):
    var pb = _cstr(path)
    _ = external_call["unlink", Int, Pointer[UInt8, origin_of(pb)]](pb.unsafe_ptr())


def _symlink(target: String, linkpath: String) -> Bool:
    _unlink(linkpath)  # idempotent
    var tb = _cstr(target)
    var lb = _cstr(linkpath)
    var rc = external_call[
        "symlink", Int,
        Pointer[UInt8, origin_of(tb)], Pointer[UInt8, origin_of(lb)],
    ](tb.unsafe_ptr(), lb.unsafe_ptr())
    return rc == 0


def main() raises:
    var r = Runner()
    var root = String("/tmp")

    # An in-root symlink pointing OUTSIDE the root must be denied (-> "").
    _ = _symlink(String("/etc"), String("/tmp/baldr_sj_escape"))
    var esc = safe_join(root, String("baldr_sj_escape/passwd"))
    r.check("symlink escape denied (empty path)", esc == String(""))

    # A symlink that resolves back WITHIN the root is allowed.
    _ = _symlink(String("/tmp"), String("/tmp/baldr_sj_inroot"))
    var ok = safe_join(root, String("baldr_sj_inroot"))
    r.check("in-root symlink allowed (non-empty)", ok != String(""))

    # An embedded NUL (%00) in a segment is rejected.
    var withnul = String("a") + chr(0) + String("b")
    r.check("NUL in segment denied (empty path)", safe_join(root, withnul) == String(""))

    # Lexical '..' is still confined to the root (regression on existing guard).
    var lex = safe_join(root, String("../../etc/passwd"))
    r.check("lexical .. confined to root", lex.startswith(String("/tmp")))

    _unlink(String("/tmp/baldr_sj_escape"))
    _unlink(String("/tmp/baldr_sj_inroot"))
    r.summary()
