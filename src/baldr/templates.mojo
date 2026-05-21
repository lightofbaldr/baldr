"""baldr.Templates — filesystem-aware wrapper around `template`.

Discovers templates lazily on first `.render()` and parses each file
exactly once unless `reload=True`. Filter set inherited from the
vendored `template` module.
"""

from std.collections import Dict
from std.pathlib import Path

from .template import Template, Value, render as template_render


struct Templates(Copyable, Movable):
    """Template directory.

    `Templates("templates/").render("page.html", ctx)` loads
    `templates/page.html`, parses on first use, and renders it with
    `ctx` (a `template.Value` dict). Subsequent `.render()` calls
    reuse the parsed AST unless `reload=True` was set on construction.
    """
    var directory: String
    var reload: Bool
    var cache_names: List[String]
    var cache_templates: List[Template]

    def __init__(out self, directory: String, reload: Bool = False):
        self.directory = directory
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
                    return template_render(self.cache_templates[i], ctx)

        var full = self.directory
        if full.byte_length() == 0 or String(full[byte=full.byte_length() - 1:]) != "/":
            full += "/"
        full += name

        var p = Path(full)
        if not p.exists() or not p.is_file():
            raise Error(String("template not found: ") + full)

        var bytes = p.read_bytes()
        var source = String(unsafe_from_utf8=bytes[:])
        var tmpl = Template(source)
        var out = template_render(tmpl, ctx)

        if not self.reload:
            self.cache_names.append(name)
            self.cache_templates.append(tmpl^)

        return out^
