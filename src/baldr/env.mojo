"""baldr.env — environment variable helpers.

Tiny wrappers over `std.os.env.getenv` that supply typed defaults,
plus a `load_dotenv()` for projects that keep their config in a `.env`
file. Every downstream baldr app eventually wants these, so they live
in the bundle rather than being reinvented per-project.

    from baldr.env import load_dotenv, env_str, env_int, env_bool

    def main() raises:
        _ = load_dotenv(String(".env"))           # silent if file missing
        var host  = env_str(String("HOST"), String("0.0.0.0"))
        var port  = env_int(String("PORT"), 8080)
        var debug = env_bool(String("DEBUG"), False)
"""

from std.ffi import external_call, c_int
from std.os.env import getenv
from std.pathlib import Path


def env_str(name: String, default: String) -> String:
    """Read a string env var; fall back to `default` if unset or empty."""
    var s = getenv(name)
    if s.byte_length() == 0:
        return default
    return s^


def env_int(name: String, default: Int) raises -> Int:
    """Read an integer env var; fall back to `default` if unset or empty.
    Raises if the value is set but not a valid integer — fail loudly on
    a typoed config rather than silently using the default."""
    var s = getenv(name)
    if s.byte_length() == 0:
        return default
    return atol(s)


def env_bool(name: String, default: Bool) -> Bool:
    """Read a boolean env var; fall back to `default` if unset or empty.

    Truthy:  1, true, yes, on   (case-insensitive)
    Falsy:   0, false, no, off  (case-insensitive)
    Anything else returns `default` — we don't raise here because
    boolean flags are commonly typoed and a silent fallback to the
    coded default is safer than crashing the binary at start-up."""
    var s = getenv(name)
    if s.byte_length() == 0:
        return default
    var lower = _lowercase(s)
    if lower == "1" or lower == "true" or lower == "yes" or lower == "on":
        return True
    if lower == "0" or lower == "false" or lower == "no" or lower == "off":
        return False
    return default


def _lowercase(s: String) -> String:
    var out = String()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            c += 32
        out += chr(c)
    return out^


# ── .env loader ───────────────────────────────────────────────────────────
def load_dotenv(path: String = String(".env"), override: Bool = False) raises -> Int:
    """Load KEY=VALUE pairs from a .env file into the process environment.

    Format:
        KEY=value                # comment after value is part of value
        KEY="quoted value"       # outer matching quotes are stripped
        KEY='also quoted'
        # full-line comments are ignored
        (blank lines ignored)

    By default, **existing env vars win** — a .env entry only fills in
    vars that aren't already set. Pass `override=True` to flip that.

    Returns the number of variables that were actually set (0 if all
    keys were already in the env, or if the file is missing).

    Missing file is *not* an error: production deployments typically
    ship without a .env (real env vars come from systemd / k8s secret),
    so callers can `_ = load_dotenv()` unconditionally."""
    var p = Path(path)
    if not p.exists() or not p.is_file():
        return 0

    var bytes = p.read_bytes()
    var source = String(unsafe_from_utf8=bytes[:])

    var set_count = 0
    var lines = source.split(String("\n"))
    for var line in lines:
        var ls = _strip_ws(String(line))
        if ls.byte_length() == 0:
            continue
        if ls.as_bytes()[0] == UInt8(35):  # '#'
            continue
        var eq = ls.find(String("="))
        if eq <= 0:
            continue
        var key = _strip_ws(String(ls[byte=0:eq]))
        var raw = _strip_ws(String(ls[byte=eq + 1:]))
        var val = _strip_quotes(raw)
        if key.byte_length() == 0:
            continue
        if not override and getenv(key).byte_length() > 0:
            continue
        _setenv_cstr(key, val)
        set_count += 1
    return set_count


def _strip_ws(s: String) -> String:
    """Trim ASCII space + tab + CR from both ends."""
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (b[i] == UInt8(32) or b[i] == UInt8(9) or b[i] == UInt8(13)):
        i += 1
    var j = n
    while j > i and (b[j - 1] == UInt8(32) or b[j - 1] == UInt8(9) or b[j - 1] == UInt8(13)):
        j -= 1
    return String(s[byte=i:j])


def _strip_quotes(s: String) -> String:
    """Strip a matching pair of leading/trailing '"' or "'"."""
    var n = s.byte_length()
    if n < 2:
        return s
    var b = s.as_bytes()
    var first = b[0]
    var last = b[n - 1]
    if (first == UInt8(34) and last == UInt8(34)) \
       or (first == UInt8(39) and last == UInt8(39)):
        return String(s[byte=1:n - 1])
    return s


def _setenv_cstr(name: String, value: String):
    """Call libc setenv(name, value, 1) — caller controls override logic."""
    var n_buf = (name + "\0").as_bytes()
    var v_buf = (value + "\0").as_bytes()
    var n_list = List[UInt8](capacity=len(n_buf))
    var v_list = List[UInt8](capacity=len(v_buf))
    for i in range(len(n_buf)):
        n_list.append(n_buf[i])
    for i in range(len(v_buf)):
        v_list.append(v_buf[i])
    _ = external_call["setenv", c_int](
        n_list.unsafe_ptr().bitcast[Int8](),
        v_list.unsafe_ptr().bitcast[Int8](),
        c_int(1),
    )
