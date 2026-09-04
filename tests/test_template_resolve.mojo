"""Executable-relative template directory resolution tests."""

from std.ffi import c_int, external_call
from std.os import chdir, makedirs
from std.os.env import getenv
from std.pathlib import Path

from baldr.http import process_execv, process_getpid
from baldr.templates import Templates, _read_proc_link


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

    def finish(self) raises:
        print("---")
        print(self.total - self.failures, "/", self.total, "passed")
        if self.failures > 0:
            raise Error("template resolution test failures: " + String(self.failures))


def _to_cstring(value: String) -> List[UInt8]:
    var bytes = (value + "\0").as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _setenv(name: String, value: String):
    var n = _to_cstring(name)
    var v = _to_cstring(value)
    _ = external_call["setenv", c_int](
        n.unsafe_ptr().unsafe_bitcast[Int8](),
        v.unsafe_ptr().unsafe_bitcast[Int8](),
        c_int(1),
    )


def _unsetenv(name: String):
    var n = _to_cstring(name)
    _ = external_call["unsetenv", c_int](n.unsafe_ptr().unsafe_bitcast[Int8]())


def _relocate_and_exec() raises:
    """Replace this process with a copy under build/tpl_<actual pid>."""
    var cwd = _read_proc_link(String("/proc/self/cwd"))
    var source = _read_proc_link(String("/proc/self/exe"))
    if cwd.byte_length() == 0 or source.byte_length() == 0:
        raise Error("could not resolve test cwd/executable")
    var root = cwd + "/build/tpl_" + String(Int(process_getpid()))
    makedirs(root, exist_ok=True)
    var relocated = root + "/test_template_resolve"
    Path(relocated).write_bytes(Path(source).read_bytes())
    var cpath = _to_cstring(relocated)
    var chmod_result = external_call["chmod", c_int](
        cpath.unsafe_ptr().unsafe_bitcast[Int8](), c_int(0o755)
    )
    if Int(chmod_result) != 0:
        raise Error("could not make relocated test executable")
    _setenv(String("BALDR_TEMPLATE_TEST_ROOT"), root)
    _setenv(String("BALDR_TEMPLATE_TEST_CHILD"), String("1"))
    var args = List[String]()
    args.append(relocated)
    var rc = process_execv(args)
    raise Error("execv failed: " + String(Int(rc)))


def main() raises:
    if getenv(String("BALDR_TEMPLATE_TEST_CHILD")).byte_length() == 0:
        _relocate_and_exec()

    var runner = Runner()
    var executable_dir = getenv(String("BALDR_TEMPLATE_TEST_ROOT"))
    if executable_dir.byte_length() == 0:
        raise Error("BALDR_TEMPLATE_TEST_ROOT must name the test binary directory")

    var template_dir = executable_dir + "/templates"
    var elsewhere = executable_dir + "/elsewhere"
    var override_dir = executable_dir + "/override"
    makedirs(template_dir, exist_ok=True)
    makedirs(elsewhere, exist_ok=True)
    makedirs(override_dir, exist_ok=True)
    Path(template_dir + "/x.html").write_text(String("from executable"))
    Path(override_dir + "/x.html").write_text(String("from override"))

    _unsetenv(String("BALDR_TEMPLATE_DIR"))
    chdir(elsewhere)

    var relative = Templates(String("templates"))
    runner.check("relative root resolves beside executable", relative.root == template_dir)
    runner.check("relative template loads away from cwd", relative.load(String("x.html")) == "from executable")

    _setenv(String("BALDR_TEMPLATE_DIR"), override_dir)
    var overridden = Templates(String("templates"))
    runner.check("BALDR_TEMPLATE_DIR overrides executable root", overridden.root == override_dir)
    runner.check("override template loads", overridden.load(String("x.html")) == "from override")

    var absolute = Templates(template_dir)
    runner.check("absolute input is untouched", absolute.root == template_dir)

    _unsetenv(String("BALDR_TEMPLATE_DIR"))
    var missing = Templates(String("missing"))
    var clear_error = False
    try:
        _ = missing.load(String("x.html"))
    except error:
        clear_error = String(error).find(String("template not found: ") + missing.root + "/x.html") >= 0
    runner.check("missing error includes resolved path", clear_error)

    chdir(executable_dir)
    _unsetenv(String("BALDR_TEMPLATE_DIR"))
    _unsetenv(String("BALDR_TEMPLATE_TEST_CHILD"))
    runner.finish()
