"""baldr.Templates — filesystem-aware wrapper around `template`.

Discovers templates lazily on first `.render()` and parses each file
exactly once unless `reload=True`. Filter set inherited from the
vendored `template` module.
"""

from std.collections import Dict
from std.ffi import c_size_t, c_ssize_t, external_call
from std.os.env import getenv
from std.pathlib import Path

from .template import Template, Value, TemplateLoader, render_with_loader as template_render


def _is_safe_template_name(name: String) -> Bool:
    """Reject template/include names that could escape the template directory:
    absolute paths, '..' path segments, backslashes, and control bytes (NUL)."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    if b[0] == UInt8(47):              # leading '/' -> absolute
        return False
    for i in range(len(b)):
        var c = b[i]
        if c < 0x20 or c == 0x7F or c == UInt8(92):  # control byte / NUL / backslash
            return False
    for var p in name.split("/"):
        if String(p) == "..":          # any traversal segment
            return False
    return True


def _is_absolute_path(path: String) -> Bool:
    return path.byte_length() > 0 and String(path[byte=0:1]) == "/"


def _join_path(base: String, child: String) -> String:
    if base.byte_length() == 0:
        return child
    if String(base[byte=base.byte_length() - 1:]) == "/":
        return base + child
    return base + "/" + child


def _dirname(path: String) -> String:
    var slash = path.rfind(String("/"))
    if slash < 0:
        return String()
    if slash == 0:
        return String("/")
    return String(path[byte=0:slash])


def _to_cstring(value: String) -> List[UInt8]:
    var bytes = (value + "\0").as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _read_proc_link(path: String) -> String:
    """Read a Linux procfs symlink, returning an empty string on failure."""
    comptime CAPACITY = 4096
    var source = _to_cstring(path)
    var buffer = List[UInt8](capacity=CAPACITY)
    for _ in range(CAPACITY):
        buffer.append(0)
    var count = external_call[
        "readlink", c_ssize_t,
        Pointer[Int8, origin_of(source)],
        Pointer[UInt8, origin_of(buffer)],
        c_size_t,
    ](
        source.unsafe_ptr().unsafe_bitcast[Int8](),
        buffer.unsafe_ptr(),
        c_size_t(CAPACITY),
    )
    if count <= 0 or Int(count) >= CAPACITY:
        return String()
    var out = String()
    for i in range(Int(count)):
        out += chr(Int(buffer[i]))
    return out^


def _resolve_template_root(directory: String) -> String:
    """Resolve a template directory without making construction raising."""
    if directory.byte_length() == 0 or _is_absolute_path(directory):
        return directory

    # An explicit deployment override owns resolution. A relative override is
    # made absolute against the process CWD so `root` remains inspectable.
    var override = getenv(String("BALDR_TEMPLATE_DIR"))
    if override.byte_length() > 0:
        if _is_absolute_path(override):
            return override^
        var cwd = _read_proc_link(String("/proc/self/cwd"))
        if cwd.byte_length() > 0:
            return _join_path(cwd, override)
        return override^

    var executable = _read_proc_link(String("/proc/self/exe"))
    if executable.byte_length() > 0:
        var executable_dir = _dirname(executable)
        var alongside = _join_path(executable_dir, directory)
        var alongside_path = Path(alongside)
        if alongside_path.exists() and alongside_path.is_dir():
            return alongside^

        var sibling = _join_path(_join_path(executable_dir, String("..")), directory)
        var sibling_path = Path(sibling)
        if sibling_path.exists() and sibling_path.is_dir():
            return sibling^

    var cwd = _read_proc_link(String("/proc/self/cwd"))
    if cwd.byte_length() > 0:
        return _join_path(cwd, directory)
    return directory


struct Templates(Copyable, Movable, TemplateLoader):
    """Template directory.

    `Templates("templates/").render("page.html", ctx)` loads
    `templates/page.html`, parses on first use, and renders it with
    `ctx` (a `template.Value` dict). Subsequent `.render()` calls
    reuse the parsed AST unless `reload=True` was set on construction.

    Conforms to `template.TemplateLoader`, so `{% include "x" %}` in any
    template resolves `x` against this same directory.
    """
    var root: String
    var directory: String
    var reload: Bool
    var cache_names: List[String]
    var cache_templates: List[Template]

    def __init__(out self, directory: String, reload: Bool = False):
        self.root = _resolve_template_root(directory)
        # Backwards-compatible public alias; new code should prefer `root`.
        self.directory = self.root
        self.reload = reload
        self.cache_names = List[String]()
        self.cache_templates = List[Template]()

    def render(mut self, name: String, ctx: Value) raises -> String:
        """Render a template by name.

        With `reload=False` (default) parses each file once and caches.
        With `reload=True` re-reads + re-parses on every call — useful
        in development.
        """
        if not self.reload:
            for i in range(len(self.cache_names)):
                if self.cache_names[i] == name:
                    return template_render(self.cache_templates[i], ctx, self)

        var src = self.load(name)
        var tmpl = Template(src)
        var out = template_render(tmpl, ctx, self)

        if not self.reload:
            self.cache_names.append(name)
            self.cache_templates.append(tmpl^)

        return out^

    def load(self, name: String) raises -> String:
        """TemplateLoader conformance: read `root/name` as a string."""
        if not _is_safe_template_name(name):
            raise Error(String("template: unsafe path (traversal/absolute): ") + name)
        var full = self.root
        if full.byte_length() == 0 or String(full[byte=full.byte_length() - 1:]) != "/":
            full += "/"
        full += name
        var p = Path(full)
        if not p.exists() or not p.is_file():
            raise Error(String("template not found: ") + full)
        var bytes = p.read_bytes()
        return String(unsafe_from_utf8=bytes[:])
