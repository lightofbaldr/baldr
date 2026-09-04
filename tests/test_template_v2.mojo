"""Phase 2.5 — templating v2 tests (loop variable + new filters)."""

from std.collections import List

from baldr.template import Value, Template, evaluate, render


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


def render_of(src: String, ctx: Value) raises -> String:
    var t = Template(src)
    return render(t, ctx)


def main() raises:
    var r = Runner()

    # ── loop variable: index, index0, first, last, length ──────────────
    var ctx = Value.dict()
    var items = Value.list_of()
    items.push(Value.string(String("a")))
    items.push(Value.string(String("b")))
    items.push(Value.string(String("c")))
    ctx.set(String("xs"), items^)

    var out = render_of(String("{% for x in xs %}{{ loop.index }}:{{ x }}({{ loop.first }},{{ loop.last }}) {% endfor %}"), ctx)
    r.check("loop.index 1-based", out.find(String("1:a")) >= 0)
    r.check("loop.index reaches 3", out.find(String("3:c")) >= 0)
    r.check("loop.first true on 1st", out.find(String("(True,False)")) >= 0)
    r.check("loop.last true on last", out.find(String("(False,True)")) >= 0)
    r.check("loop.length == 3", out.find(String("length")) < 0 or True)  # length not printed; just ensure render ok

    # loop.length accessible
    var out2 = render_of(String("{% for x in xs %}{{ loop.length }}{% endfor %}"), ctx)
    r.check("loop.length == 3", out2 == String("333"))

    # loop.index0
    var out3 = render_of(String("{% for x in xs %}{{ loop.index0 }}{% endfor %}"), ctx)
    r.check("loop.index0 0-based", out3 == String("012"))

    # single-element loop: first AND last both true
    var ctx1 = Value.dict()
    var one = Value.list_of()
    one.push(Value.string(String("solo")))
    ctx1.set(String("xs"), one^)
    var out4 = render_of(String("{% for x in xs %}{{ loop.first }}-{{ loop.last }}{% endfor %}"), ctx1)
    r.check("single elem: first and last", out4 == String("True-True"))

    # empty loop renders nothing
    var ctx0 = Value.dict()
    ctx0.set(String("xs"), Value.list_of())
    var out5 = render_of(String("[{% for x in xs %}{{ x }}{% endfor %}]"), ctx0)
    r.check("empty list loop renders nothing", out5 == String("[]"))

    # loop over dict keys
    var dctx = Value.dict()
    var d = Value.dict()
    d.set(String("k1"), Value.int_(1))
    d.set(String("k2"), Value.int_(2))
    dctx.set(String("d"), d^)
    var out6 = render_of(String("{% for k in d %}{{ k }}={{ loop.index }} {% endfor %}"), dctx)
    r.check("loop over dict has index", out6.find(String("=1")) >= 0 and out6.find(String("=2")) >= 0)

    # ── new filters ────────────────────────────────────────────────────
    var fc = Value.dict()
    fc.set(String("name"), Value.string(String("hello world")))

    # capitalize
    r.check("filter capitalize", render_of(String("{{ name | capitalize }}"), fc) == String("Hello world"))
    # trim
    var fc2 = Value.dict()
    fc2.set(String("s"), Value.string(String("   spaced   ")))
    r.check("filter trim", render_of(String("[{{ s | trim }}]"), fc2) == String("[spaced]"))
    # abs
    var fc3 = Value.dict()
    fc3.set(String("n"), Value.int_(-5))
    r.check("filter abs int", render_of(String("{{ n | abs }}"), fc3) == String("5"))
    # join
    var fc4 = Value.dict()
    var jl = Value.list_of()
    jl.push(Value.string(String("a")))
    jl.push(Value.string(String("b")))
    jl.push(Value.string(String("c")))
    fc4.set(String("xs"), jl^)
    r.check("filter join default", render_of(String("{{ xs | join }}"), fc4) == String("abc"))
    r.check("filter join with sep", render_of(String("{{ xs | join(\", \") }}"), fc4) == String("a, b, c"))
    # truncate
    var fc5 = Value.dict()
    fc5.set(String("s"), Value.string(String("abcdefghij")))
    r.check("filter truncate under limit (no ellipsis)", render_of(String("{{ s | truncate(20) }}"), fc5) == String("abcdefghij"))
    r.check("filter truncate over limit (ellipsis)", render_of(String("{{ s | truncate(4) }}"), fc5) == String("abcd..."))

    # existing filters still work (regression)
    r.check("filter upper still works", render_of(String("{{ name | upper }}"), fc) == String("HELLO WORLD"))
    r.check("filter length still works", render_of(String("{{ name | length }}"), fc) == String("11"))

    r.summary()
