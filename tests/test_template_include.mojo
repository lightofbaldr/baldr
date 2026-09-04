"""Phase 2.5 — {% include %} tests.

Exercises the TemplateLoader path: standalone `render` raises on include
(NoLoader), `render_with_loader` resolves partials, includes can nest, and
the filesystem `Templates` wrapper supports includes end-to-end.
"""


from std.collections import Dict, List
from std.os import mkdir
from std.time import perf_counter_ns
from std.pathlib import Path

from baldr.template import Template, Value, render, render_with_loader, TemplateLoader, NoLoader
from baldr.templates import Templates


# A pure in-memory loader for deterministic unit tests (no filesystem).
@fieldwise_init
struct MemLoader(TemplateLoader, Copyable, Movable):
    var names: List[String]
    var sources: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.sources = List[String]()

    def add(mut self, name: String, src: String):
        self.names.append(name)
        self.sources.append(src)

    def load(self, name: String) raises -> String:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.sources[i].copy()
        raise Error(String("template: partial not found: ") + name)


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
            print(self.total - self.failures, "/", self.total, "passed", "—", self.failures, "FAILED")


def main() raises:
    var r = Runner()

    # ── standalone render (NoLoader) raises on include ─────────────────
    var t = Template(String("A{% include \"x\" %}B"))
    var raised = False
    try:
        _ = render(t, Value.dict())
    except:
        raised = True
    r.check("render without loader raises on include", raised)

    # ── render_with_loader resolves a partial ──────────────────────────
    var loader = MemLoader()
    loader.add(String("x"), String("[X]"))
    var out = render_with_loader[ MemLoader ](t, Value.dict(), loader)
    r.check("include resolves partial", out == String("A[X]B"))

    # ── partial sees the current context ───────────────────────────────
    var loader2 = MemLoader()
    loader2.add(String("greet"), String("hi {{ who }}"))
    var t2 = Template(String("{% include \"greet\" %}!"))
    var ctx = Value.dict()
    ctx.set(String("who"), Value.string(String("ada")))
    var out2 = render_with_loader[ MemLoader ](t2, ctx, loader2)
    r.check("partial sees context", out2 == String("hi ada!"))

    # ── nested includes ────────────────────────────────────────────────
    var loader3 = MemLoader()
    loader3.add(String("outer"), String("O({% include \"inner\" %})O"))
    loader3.add(String("inner"), String("I"))
    var t3 = Template(String("[{% include \"outer\" %}]"))
    var out3 = render_with_loader[ MemLoader ](t3, Value.dict(), loader3)
    r.check("nested includes resolve", out3 == String("[O(I)O]"))

    # ── include inside a for loop gets loop context ────────────────────
    var loader4 = MemLoader()
    loader4.add(String("row"), String("{{ x }}@{{ loop.index }} "))
    var t4 = Template(String("{% for x in xs %}{% include \"row\" %}{% endfor %}"))
    var ctx4 = Value.dict()
    var xs = Value.list_of()
    xs.push(Value.string(String("a")))
    xs.push(Value.string(String("b")))
    ctx4.set(String("xs"), xs^)
    var out4 = render_with_loader[ MemLoader ](t4, ctx4, loader4)
    r.check("include in for-loop sees loop var", out4.find(String("a@1")) >= 0 and out4.find(String("b@2")) >= 0)

    # ── filesystem Templates wrapper supports include end-to-end ───────
    var tmpdir = String("/tmp/baldr_include_test_") + String(perf_counter_ns())
    _ = mkdir(tmpdir, 0o755)
    Path(tmpdir + String("/page.html")).write_text(String("PAGE[{% include \"nav.html\" %}]"))
    Path(tmpdir + String("/nav.html")).write_text(String("NAV"))

    var templates = Templates(tmpdir + String("/"))
    var fs_out = templates.render(String("page.html"), Value.dict())
    r.check("filesystem Templates include", fs_out == String("PAGE[NAV]"))

    # missing partial raises
    var t5 = Template(String("{% include \"nope\" %}"))
    var raised2 = False
    try:
        _ = render_with_loader[ MemLoader ](t5, Value.dict(), MemLoader())
    except:
        raised2 = True
    r.check("missing partial raises", raised2)

    # ── empty {% include %} raises a clean error (regression: it used to
    #    slice arg[byte=-1:] and crash before the quote check) ───────────
    var raised_empty = False
    try:
        var te = Template(String("A{% include %}B"))
        _ = render_with_loader[ MemLoader ](te, Value.dict(), MemLoader())
    except:
        raised_empty = True
    r.check("empty include raises cleanly", raised_empty)

    # ── cyclic / self include is depth-capped, not a stack overflow ────
    var loaderC = MemLoader()
    loaderC.add(String("loop"), String("x{% include \"loop\" %}"))
    var tc = Template(String("{% include \"loop\" %}"))
    var raised_cycle = False
    try:
        _ = render_with_loader[ MemLoader ](tc, Value.dict(), loaderC)
    except:
        raised_cycle = True
    r.check("cyclic include raises (depth cap) not overflow", raised_cycle)

    r.summary()
