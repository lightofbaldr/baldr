"""Tests for baldr.env. Uses libc setenv to set / unset the var
inside the test process — no shell or pixi-task variance."""

from std.ffi import external_call, c_int
from std.os import makedirs
from std.pathlib import Path

from baldr.env import env_str, env_int, env_bool, load_dotenv


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

    def summary(self):
        print("---")
        if self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.failures, "of", self.total, "FAILED")


def _to_cstring(s: String) -> List[UInt8]:
    """Append a NUL terminator and return a List the test can hold
    while libc reads from `.unsafe_ptr()`."""
    var b = (s + "\0").as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _setenv(name: String, value: String):
    var n = _to_cstring(name)
    var v = _to_cstring(value)
    _ = external_call["setenv", c_int](
        n.unsafe_ptr().bitcast[Int8](),
        v.unsafe_ptr().bitcast[Int8](),
        c_int(1),
    )


def _unsetenv(name: String):
    var n = _to_cstring(name)
    _ = external_call["unsetenv", c_int](
        n.unsafe_ptr().bitcast[Int8](),
    )


# ── env_str ───────────────────────────────────────────────────────────────
def test_env_str_default_when_unset(mut r: Runner) raises:
    _unsetenv(String("BALDR_TEST_S"))
    r.check(String("env_str returns default when unset"),
        env_str(String("BALDR_TEST_S"), String("fallback")) == "fallback")


def test_env_str_value_when_set(mut r: Runner) raises:
    _setenv(String("BALDR_TEST_S"), String("hello"))
    r.check(String("env_str returns value"),
        env_str(String("BALDR_TEST_S"), String("fallback")) == "hello")
    _unsetenv(String("BALDR_TEST_S"))


def test_env_str_empty_treated_as_unset(mut r: Runner) raises:
    _setenv(String("BALDR_TEST_S"), String(""))
    r.check(String("env_str empty -> default"),
        env_str(String("BALDR_TEST_S"), String("fallback")) == "fallback")
    _unsetenv(String("BALDR_TEST_S"))


# ── env_int ───────────────────────────────────────────────────────────────
def test_env_int_default_when_unset(mut r: Runner) raises:
    _unsetenv(String("BALDR_TEST_I"))
    r.check(String("env_int default when unset"),
        env_int(String("BALDR_TEST_I"), 42) == 42)


def test_env_int_value_when_set(mut r: Runner) raises:
    _setenv(String("BALDR_TEST_I"), String("8080"))
    r.check(String("env_int parses int"),
        env_int(String("BALDR_TEST_I"), 0) == 8080)
    _unsetenv(String("BALDR_TEST_I"))


def test_env_int_invalid_raises(mut r: Runner) raises:
    _setenv(String("BALDR_TEST_I"), String("not-a-number"))
    var raised = False
    try:
        _ = env_int(String("BALDR_TEST_I"), 0)
    except:
        raised = True
    r.check(String("env_int raises on garbage"), raised)
    _unsetenv(String("BALDR_TEST_I"))


# ── env_bool ──────────────────────────────────────────────────────────────
def test_env_bool_default_when_unset(mut r: Runner) raises:
    _unsetenv(String("BALDR_TEST_B"))
    r.check(String("env_bool default True"),
        env_bool(String("BALDR_TEST_B"), True))
    r.check(String("env_bool default False"),
        not env_bool(String("BALDR_TEST_B"), False))


def test_env_bool_truthy(mut r: Runner) raises:
    var truthy = List[String]()
    truthy.append(String("1"))
    truthy.append(String("true"))
    truthy.append(String("True"))
    truthy.append(String("TRUE"))
    truthy.append(String("yes"))
    truthy.append(String("on"))
    for i in range(len(truthy)):
        _setenv(String("BALDR_TEST_B"), truthy[i])
        r.check(String("truthy: ") + truthy[i],
            env_bool(String("BALDR_TEST_B"), False))
    _unsetenv(String("BALDR_TEST_B"))


def test_env_bool_falsy(mut r: Runner) raises:
    var falsy = List[String]()
    falsy.append(String("0"))
    falsy.append(String("false"))
    falsy.append(String("False"))
    falsy.append(String("no"))
    falsy.append(String("off"))
    for i in range(len(falsy)):
        _setenv(String("BALDR_TEST_B"), falsy[i])
        r.check(String("falsy: ") + falsy[i],
            not env_bool(String("BALDR_TEST_B"), True))
    _unsetenv(String("BALDR_TEST_B"))


def test_env_bool_unknown_returns_default(mut r: Runner) raises:
    _setenv(String("BALDR_TEST_B"), String("maybe"))
    r.check(String("unknown -> default True"),
        env_bool(String("BALDR_TEST_B"), True))
    r.check(String("unknown -> default False"),
        not env_bool(String("BALDR_TEST_B"), False))
    _unsetenv(String("BALDR_TEST_B"))


# ── load_dotenv ───────────────────────────────────────────────────────────
def _write_dotenv(path: String, content: String) raises:
    var p = Path(path)
    var b = content.as_bytes()
    var L = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        L.append(b[i])
    p.write_bytes(L)


def test_dotenv_missing_file_returns_zero(mut r: Runner) raises:
    var n = load_dotenv(String("/tmp/baldr_no_such.env"))
    r.check(String("missing file → 0, no raise"), n == 0)


def test_dotenv_basic(mut r: Runner, tmpdir: String) raises:
    _unsetenv(String("BALDR_DE_A"))
    _unsetenv(String("BALDR_DE_B"))
    _write_dotenv(tmpdir + "/.env",
        String("BALDR_DE_A=alpha\nBALDR_DE_B=beta\n"))
    var n = load_dotenv(String(tmpdir + "/.env"))
    r.check(String("loaded 2 vars"), n == 2)
    r.check(String("DE_A set"), env_str(String("BALDR_DE_A"), String("?")) == "alpha")
    r.check(String("DE_B set"), env_str(String("BALDR_DE_B"), String("?")) == "beta")
    _unsetenv(String("BALDR_DE_A"))
    _unsetenv(String("BALDR_DE_B"))


def test_dotenv_skips_comments_and_blanks(mut r: Runner, tmpdir: String) raises:
    _unsetenv(String("BALDR_DE_C"))
    _write_dotenv(tmpdir + "/cm.env",
        String("# header comment\n\nBALDR_DE_C=gamma\n   # indented comment ignored too\n\n"))
    var n = load_dotenv(String(tmpdir + "/cm.env"))
    r.check(String("only the 1 real line counted"), n == 1)
    r.check(String("DE_C set"), env_str(String("BALDR_DE_C"), String("?")) == "gamma")
    _unsetenv(String("BALDR_DE_C"))


def test_dotenv_quoted_values(mut r: Runner, tmpdir: String) raises:
    _unsetenv(String("BALDR_DE_DBL"))
    _unsetenv(String("BALDR_DE_SGL"))
    _unsetenv(String("BALDR_DE_MIX"))
    _write_dotenv(tmpdir + "/q.env",
        String("BALDR_DE_DBL=\"double quoted\"\n")
        + "BALDR_DE_SGL='single quoted'\n"
        + "BALDR_DE_MIX=\"mismatched'\n")
    _ = load_dotenv(String(tmpdir + "/q.env"))
    r.check(String("double quotes stripped"),
        env_str(String("BALDR_DE_DBL"), String("?")) == "double quoted")
    r.check(String("single quotes stripped"),
        env_str(String("BALDR_DE_SGL"), String("?")) == "single quoted")
    r.check(String("mismatched quotes left alone"),
        env_str(String("BALDR_DE_MIX"), String("?")) == "\"mismatched'")
    _unsetenv(String("BALDR_DE_DBL"))
    _unsetenv(String("BALDR_DE_SGL"))
    _unsetenv(String("BALDR_DE_MIX"))


def test_dotenv_existing_env_wins(mut r: Runner, tmpdir: String) raises:
    _setenv(String("BALDR_DE_KEEP"), String("from-env"))
    _write_dotenv(tmpdir + "/keep.env",
        String("BALDR_DE_KEEP=from-file\n"))
    var n = load_dotenv(String(tmpdir + "/keep.env"))
    r.check(String("existing var preserved (override=False)"),
        env_str(String("BALDR_DE_KEEP"), String("?")) == "from-env")
    r.check(String("count reports 0 sets"), n == 0)
    _unsetenv(String("BALDR_DE_KEEP"))


def test_dotenv_override_true(mut r: Runner, tmpdir: String) raises:
    _setenv(String("BALDR_DE_OVER"), String("from-env"))
    _write_dotenv(tmpdir + "/over.env",
        String("BALDR_DE_OVER=from-file\n"))
    var n = load_dotenv(String(tmpdir + "/over.env"), override=True)
    r.check(String("override=True replaces"),
        env_str(String("BALDR_DE_OVER"), String("?")) == "from-file")
    r.check(String("count reports 1 set"), n == 1)
    _unsetenv(String("BALDR_DE_OVER"))


def test_dotenv_whitespace_around_equals(mut r: Runner, tmpdir: String) raises:
    _unsetenv(String("BALDR_DE_WS"))
    _write_dotenv(tmpdir + "/ws.env",
        String("   BALDR_DE_WS   =   spaced   \n"))
    _ = load_dotenv(String(tmpdir + "/ws.env"))
    r.check(String("key + value stripped"),
        env_str(String("BALDR_DE_WS"), String("?")) == "spaced")
    _unsetenv(String("BALDR_DE_WS"))


def main() raises:
    var r = Runner()

    test_env_str_default_when_unset(r)
    test_env_str_value_when_set(r)
    test_env_str_empty_treated_as_unset(r)

    test_env_int_default_when_unset(r)
    test_env_int_value_when_set(r)
    test_env_int_invalid_raises(r)

    test_env_bool_default_when_unset(r)
    test_env_bool_truthy(r)
    test_env_bool_falsy(r)
    test_env_bool_unknown_returns_default(r)

    var tmpdir = String("/tmp/baldr_env_tests")
    try:
        makedirs(tmpdir, exist_ok=True)
    except:
        pass

    test_dotenv_missing_file_returns_zero(r)
    test_dotenv_basic(r, tmpdir)
    test_dotenv_skips_comments_and_blanks(r, tmpdir)
    test_dotenv_quoted_values(r, tmpdir)
    test_dotenv_existing_env_wins(r, tmpdir)
    test_dotenv_override_true(r, tmpdir)
    test_dotenv_whitespace_around_equals(r, tmpdir)

    r.summary()
