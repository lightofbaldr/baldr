"""Test suite for mojo-template.

Standalone driver — `pixi run test` builds and runs this. Mojo 1.0 has
no per-module test runner yet, so we use the same Runner-struct pattern
as mojo-json.
"""

from baldr.template import Value, Template, render, evaluate


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int

    def __init__(out self):
        self.total = 0
        self.failures = 0


def expect_eq(mut r: Runner, name: String, got: String, want: String):
    r.total += 1
    if got == want:
        print("[ok]", name)
    else:
        r.failures += 1
        print("[FAIL]", name)
        print("  got: ", repr(got))
        print("  want:", repr(want))


def render_str(src: String, ctx: Value) raises -> String:
    var t = Template(src)
    return render(t, ctx)


def repr(s: String) -> String:
    return '"' + s + '"'


# ── tests ───────────────────────────────────────────────────────────────
def test_literal(mut r: Runner) raises:
    expect_eq(r, "plain text", render_str("hello", Value.dict()), String("hello"))
    expect_eq(r, "no tags", render_str("<p>x</p>", Value.dict()), String("<p>x</p>"))


def test_interpolation(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("name", Value.string("adam"))
    expect_eq(r, "var simple", render_str("hi {{ name }}", ctx), String("hi adam"))
    expect_eq(r, "var no spaces", render_str("{{name}}!", ctx), String("adam!"))


def test_autoescape(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("html", Value.string("<b>'x'&y</b>"))
    expect_eq(r, "auto escape", render_str("{{ html }}", ctx),
              String("&lt;b&gt;&#39;x&#39;&amp;y&lt;/b&gt;"))
    expect_eq(r, "safe disables", render_str("{{ html|safe }}", ctx),
              String("<b>'x'&y</b>"))


def test_autoescape_utf8(mut r: Runner) raises:
    """Multi-byte UTF-8 must survive auto-escape without re-encoding.

    Regression for a real bug: building escaped output with
    `out += chr(Int(byte))` double-encodes every byte ≥ 0x80 because
    chr() interprets its arg as a *codepoint*. So "·" (0xC2 0xB7)
    became "Â·" (0xC3 0x82 0xC3 0x82 0xC2 0xB7) on a real page.
    The fix: accumulate raw bytes and convert via unsafe_from_utf8.
    """
    var ctx = Value.dict()
    # Middle dot: U+00B7, encoded as 0xC2 0xB7 (2 bytes)
    ctx.set("mid", Value.string("Spark 2 · GB10 · Mojo 1.0"))
    # Em dash: U+2014, encoded as 0xE2 0x80 0x94 (3 bytes)
    ctx.set("em",  Value.string("none — fills the gap"))
    # Emoji: U+1F525 (fire), encoded as 0xF0 0x9F 0x94 0xA5 (4 bytes)
    ctx.set("fire", Value.string("hot 🔥 stuff"))

    expect_eq(r, "utf8 2-byte middot",
              render_str("{{ mid }}", ctx),
              String("Spark 2 · GB10 · Mojo 1.0"))
    expect_eq(r, "utf8 3-byte em dash",
              render_str("{{ em }}", ctx),
              String("none — fills the gap"))
    expect_eq(r, "utf8 4-byte emoji",
              render_str("{{ fire }}", ctx),
              String("hot 🔥 stuff"))
    expect_eq(r, "utf8 mixed with html-escape",
              render_str("{{ \"<·>\" }}", ctx),
              String("&lt;·&gt;"))


def test_filters(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("name", Value.string("Adam"))
    expect_eq(r, "upper", render_str("{{ name|upper }}", ctx), String("ADAM"))
    expect_eq(r, "lower", render_str("{{ name|lower }}", ctx), String("adam"))
    ctx.set("xs", Value.list_of())
    ctx.get("xs")  # just to exercise get
    var xs = Value.list_of()
    xs.push(Value.int_(1)); xs.push(Value.int_(2)); xs.push(Value.int_(3))
    ctx.set("xs", xs^)
    expect_eq(r, "length list", render_str("{{ xs|length }}", ctx), String("3"))
    expect_eq(r, "length string", render_str("{{ name|length }}", ctx), String("4"))


def test_default(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("name", Value.string("adam"))
    # `missing` not in ctx → None → falsy → default fires.
    expect_eq(r, "default missing",
              render_str('{{ missing|default("anonymous") }}', ctx),
              String("anonymous"))
    expect_eq(r, "default present",
              render_str('{{ name|default("anonymous") }}', ctx),
              String("adam"))


def test_if(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("ok", Value.bool_(True))
    ctx.set("not_ok", Value.bool_(False))
    expect_eq(r, "if true",
              render_str("{% if ok %}YES{% endif %}", ctx),
              String("YES"))
    expect_eq(r, "if false",
              render_str("{% if not_ok %}YES{% endif %}", ctx),
              String(""))
    expect_eq(r, "if else (false)",
              render_str("{% if not_ok %}YES{% else %}NO{% endif %}", ctx),
              String("NO"))
    expect_eq(r, "elif chain",
              render_str("{% if not_ok %}A{% elif ok %}B{% else %}C{% endif %}", ctx),
              String("B"))


def test_cmp_in_if(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("age", Value.int_(38))
    expect_eq(r, "if ==",
              render_str("{% if age == 38 %}adult{% endif %}", ctx),
              String("adult"))
    expect_eq(r, "if >",
              render_str("{% if age > 21 %}adult{% else %}kid{% endif %}", ctx),
              String("adult"))
    expect_eq(r, "if <",
              render_str("{% if age < 21 %}kid{% else %}adult{% endif %}", ctx),
              String("adult"))
    ctx.set("name", Value.string("adam"))
    expect_eq(r, "if string ==",
              render_str('{% if name == "adam" %}me{% endif %}', ctx),
              String("me"))


def test_logical(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("a", Value.bool_(True))
    ctx.set("b", Value.bool_(False))
    expect_eq(r, "and short-circuit",
              render_str("{% if a and b %}Y{% else %}N{% endif %}", ctx),
              String("N"))
    expect_eq(r, "or",
              render_str("{% if a or b %}Y{% else %}N{% endif %}", ctx),
              String("Y"))
    expect_eq(r, "not",
              render_str("{% if not b %}Y{% else %}N{% endif %}", ctx),
              String("Y"))


def test_for_list(mut r: Runner) raises:
    var ctx = Value.dict()
    var xs = Value.list_of()
    xs.push(Value.string("a"))
    xs.push(Value.string("b"))
    xs.push(Value.string("c"))
    ctx.set("xs", xs^)
    expect_eq(r, "for list",
              render_str("{% for x in xs %}<{{ x }}>{% endfor %}", ctx),
              String("<a><b><c>"))


def test_for_dict(mut r: Runner) raises:
    var ctx = Value.dict()
    var d = Value.dict()
    d.set("a", Value.int_(1))
    d.set("b", Value.int_(2))
    ctx.set("d", d^)
    # for-on-dict yields keys (Python dict iteration semantics).
    expect_eq(r, "for dict keys",
              render_str("{% for k in d %}{{ k }},{% endfor %}", ctx),
              String("a,b,"))


def test_dotted(mut r: Runner) raises:
    var ctx = Value.dict()
    var user = Value.dict()
    user.set("name", Value.string("adam"))
    var addr = Value.dict()
    addr.set("city", Value.string("chicago"))
    user.set("addr", addr^)
    ctx.set("user", user^)
    expect_eq(r, "dotted access",
              render_str("{{ user.name }} from {{ user.addr.city }}", ctx),
              String("adam from chicago"))


def test_comment(mut r: Runner) raises:
    var ctx = Value.dict()
    expect_eq(r, "comment dropped",
              render_str("a{# hidden #}b", ctx),
              String("ab"))


def test_realistic(mut r: Runner) raises:
    """A small page-shaped template exercising several features at once."""
    var ctx = Value.dict()
    ctx.set("title", Value.string("Hello & welcome"))
    var users = Value.list_of()
    var u1 = Value.dict()
    u1.set("name", Value.string("adam"))
    u1.set("active", Value.bool_(True))
    var u2 = Value.dict()
    u2.set("name", Value.string("bob"))
    u2.set("active", Value.bool_(False))
    users.push(u1^); users.push(u2^)
    ctx.set("users", users^)

    var src = "<h1>{{ title }}</h1><ul>{% for u in users %}<li>{{ u.name }}{% if u.active %} (active){% endif %}</li>{% endfor %}</ul>"
    var want = "<h1>Hello &amp; welcome</h1><ul><li>adam (active)</li><li>bob</li></ul>"
    expect_eq(r, "realistic page", render_str(src, ctx), String(want))


def test_truthiness(mut r: Runner) raises:
    var ctx = Value.dict()
    ctx.set("empty_str", Value.string(""))
    ctx.set("zero_int",  Value.int_(0))
    ctx.set("empty_list", Value.list_of())
    ctx.set("filled_str", Value.string("x"))
    expect_eq(r, "empty string falsy",
              render_str("{% if empty_str %}Y{% else %}N{% endif %}", ctx),
              String("N"))
    expect_eq(r, "zero int falsy",
              render_str("{% if zero_int %}Y{% else %}N{% endif %}", ctx),
              String("N"))
    expect_eq(r, "empty list falsy",
              render_str("{% if empty_list %}Y{% else %}N{% endif %}", ctx),
              String("N"))
    expect_eq(r, "filled string truthy",
              render_str("{% if filled_str %}Y{% else %}N{% endif %}", ctx),
              String("Y"))


def main() raises:
    var r = Runner()
    test_literal(r)
    test_interpolation(r)
    test_autoescape(r)
    test_autoescape_utf8(r)
    test_filters(r)
    test_default(r)
    test_if(r)
    test_cmp_in_if(r)
    test_logical(r)
    test_for_list(r)
    test_for_dict(r)
    test_dotted(r)
    test_comment(r)
    test_truthiness(r)
    test_realistic(r)

    print("---")
    print(String(r.total - r.failures), "/", String(r.total), "passed")
    if r.failures > 0:
        raise Error("test failures: " + String(r.failures))
