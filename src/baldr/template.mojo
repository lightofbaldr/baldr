"""mojo-template — a pure-Mojo Jinja2-inspired HTML template engine.

The template layer of the lightofbaldr Mojo web stack:
    mojo-http   →   mojo-serve   →   mojo-template   →   browser
                                        ↑
                                        you are here

Quick start:

    from template import Value, Template, render

    var tpl = Template(\"\"\"
        <h1>{{ title|escape }}</h1>
        <ul>
        {% for u in users %}
            <li>{{ u.name }}{% if u.active %} (active){% endif %}</li>
        {% endfor %}
        </ul>
    \"\"\")
    var ctx = Value.dict()
    ctx.set(\"title\", Value.string(\"Hello & welcome\"))
    var users = Value.list_of()
    var u1 = Value.dict(); u1.set(\"name\", Value.string(\"adam\")); u1.set(\"active\", Value.bool_(True))
    var u2 = Value.dict(); u2.set(\"name\", Value.string(\"bob\")); u2.set(\"active\", Value.bool_(False))
    users.push(u1^); users.push(u2^)
    ctx.set(\"users\", users^)
    print(render(tpl, ctx))

What v0.1 covers:

- `{{ expr }}` variable interpolation (auto-HTML-escaped)
- `{% if expr %}` / `{% elif expr %}` / `{% else %}` / `{% endif %}`
- `{% for var in expr %}` / `{% endfor %}` (lists and dicts)
- `{# comment #}` comments
- Dotted attribute access: `user.name`, `a.b.c`
- Filters: `escape` / `e` / `safe` / `upper` / `lower` / `length` / `default(arg)`
- Comparisons in conditions: `==`, `!=`, `<`, `<=`, `>`, `>=`
- Logical operators: `and`, `or`, `not`
- Literals: numbers, double-quoted strings, `true`, `false`, `none`
- Truthiness rules in conditions (None/empty/zero is falsy)
- Auto-escape on `{{ }}` by default; opt out via `|safe`

What's NOT in v0.1 (queued v0.2+):
- `{% extends %}` / `{% block %}` template inheritance
- `{% include %}` partial templates
- Whitespace-control modifiers (`{%-` / `-%}`)
- Arithmetic in expressions (+ - * /)
- More built-in filters (truncate, replace, join, ...)
- Custom filters registered by the caller
- Macros / set / with blocks
- Streaming render (we always return a fully materialized String)
"""

from std.collections import Dict


# ──────────────────────────────────────────────────────────────────────────
# Value — the runtime value type used for template context AND expression
# evaluation. Six tags. Stored on the struct directly so Copyable/Movable
# behave; only one field per tag is meaningful at a time.
# ──────────────────────────────────────────────────────────────────────────

comptime V_NONE:   Int = 0
comptime V_BOOL:   Int = 1
comptime V_INT:    Int = 2
comptime V_FLOAT:  Int = 3
comptime V_STRING: Int = 4
comptime V_LIST:   Int = 5
comptime V_DICT:   Int = 6


struct Value(Copyable, Movable):
    var tag: Int
    var b: Bool
    var i: Int
    var f: Float64
    var s: String
    var items: List[Value]
    var keys: List[String]
    var vals: List[Value]

    def __init__(out self):
        self.tag = V_NONE
        self.b = False
        self.i = 0
        self.f = 0.0
        self.s = String()
        self.items = List[Value]()
        self.keys = List[String]()
        self.vals = List[Value]()

    # Constructors.
    @staticmethod
    def none() -> Value: return Value()

    @staticmethod
    def bool_(b: Bool) -> Value:
        var v = Value(); v.tag = V_BOOL; v.b = b; return v^

    @staticmethod
    def int_(i: Int) -> Value:
        var v = Value(); v.tag = V_INT; v.i = i; return v^

    @staticmethod
    def float_(f: Float64) -> Value:
        var v = Value(); v.tag = V_FLOAT; v.f = f; return v^

    @staticmethod
    def string(s: String) -> Value:
        var v = Value(); v.tag = V_STRING; v.s = s; return v^

    @staticmethod
    def list_of() -> Value:
        var v = Value(); v.tag = V_LIST; return v^

    @staticmethod
    def dict() -> Value:
        var v = Value(); v.tag = V_DICT; return v^

    # Mutation helpers (lists / dicts).
    def push(mut self, var item: Value):
        self.items.append(item^)

    def set(mut self, key: String, var value: Value):
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.vals[i] = value^
                return
        self.keys.append(key)
        self.vals.append(value^)

    def has(self, key: String) -> Bool:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return True
        return False

    def get(self, key: String) -> Value:
        for i in range(len(self.keys) - 1, -1, -1):
            if self.keys[i] == key:
                return self.vals[i].copy()
        return Value.none()

    # Truthiness rules: None=False, Bool=itself, Int/Float=nonzero,
    # String/List/Dict=non-empty.
    def truthy(self) -> Bool:
        if self.tag == V_NONE:   return False
        if self.tag == V_BOOL:   return self.b
        if self.tag == V_INT:    return self.i != 0
        if self.tag == V_FLOAT:  return self.f != 0.0
        if self.tag == V_STRING: return self.s.byte_length() > 0
        if self.tag == V_LIST:   return len(self.items) > 0
        if self.tag == V_DICT:   return len(self.keys) > 0
        return False

    # Stringification used by `{{ ... }}` output. Mirrors Python's str()
    # for the common cases.
    def to_str(self) -> String:
        if self.tag == V_NONE:   return String("")
        if self.tag == V_BOOL:   return String("True") if self.b else String("False")
        if self.tag == V_INT:    return String(self.i)
        if self.tag == V_FLOAT:
            var s = String(self.f)
            # Drop trailing ".0" for exact integers.
            if s.endswith(".0"):
                return String(s[byte=:s.byte_length() - 2])
            return s^
        if self.tag == V_STRING: return self.s
        if self.tag == V_LIST:
            var out = String("[")
            for i in range(len(self.items)):
                if i > 0: out += ", "
                out += self.items[i].to_str()
            out += "]"
            return out^
        if self.tag == V_DICT:
            var out = String("{")
            for i in range(len(self.keys)):
                if i > 0: out += ", "
                out += self.keys[i] + ": " + self.vals[i].to_str()
            out += "}"
            return out^
        return String("?")

    # Equality (used by `==` / `!=` in conditionals).
    def eq(self, other: Value) -> Bool:
        if self.tag != other.tag:
            # Allow int↔float comparison numerically.
            if (self.tag == V_INT and other.tag == V_FLOAT) \
            or (self.tag == V_FLOAT and other.tag == V_INT):
                return self.as_float() == other.as_float()
            return False
        if self.tag == V_NONE:   return True
        if self.tag == V_BOOL:   return self.b == other.b
        if self.tag == V_INT:    return self.i == other.i
        if self.tag == V_FLOAT:  return self.f == other.f
        if self.tag == V_STRING: return self.s == other.s
        # Lists/dicts: structural equality, recursive.
        if self.tag == V_LIST:
            if len(self.items) != len(other.items): return False
            for i in range(len(self.items)):
                if not self.items[i].eq(other.items[i]): return False
            return True
        if self.tag == V_DICT:
            if len(self.keys) != len(other.keys): return False
            for i in range(len(self.keys)):
                if not other.has(self.keys[i]): return False
                if not self.vals[i].eq(other.get(self.keys[i])): return False
            return True
        return False

    def as_float(self) -> Float64:
        if self.tag == V_INT: return Float64(self.i)
        if self.tag == V_FLOAT: return self.f
        if self.tag == V_BOOL: return 1.0 if self.b else 0.0
        return 0.0

    # `<` for ordering. Only meaningful on numbers and strings.
    def lt(self, other: Value) -> Bool:
        if self.tag == V_STRING and other.tag == V_STRING:
            return self.s < other.s
        return self.as_float() < other.as_float()


# ──────────────────────────────────────────────────────────────────────────
# Lexer — split a template source into TEXT / EXPR / STMT / COMMENT tokens.
# ──────────────────────────────────────────────────────────────────────────

comptime TOK_TEXT:    Int = 0
comptime TOK_EXPR:    Int = 1   # {{ ... }}
comptime TOK_STMT:    Int = 2   # {% ... %}
comptime TOK_COMMENT: Int = 3   # {# ... #}


@fieldwise_init
struct Token(Copyable, ImplicitlyCopyable, Movable):
    """Tagged token. ImplicitlyCopyable because we hand it around freely
    in the parser and the underlying String is reasonable to clone."""
    var kind: Int
    var body: String


@fieldwise_init
struct EvalResult(Copyable, Movable):
    """Return type for evaluator entry points that also report whether
    the filter chain ended in `|safe`."""
    var value: Value
    var safe: Bool


def _scan_until(src: String, start: Int, end_marker: String) raises -> Int:
    """Return the byte index of `end_marker` at or after `start`, or raise."""
    var idx = src.find(end_marker, start)
    if idx < 0:
        raise Error("template: unterminated tag, missing '" + end_marker + "'")
    return idx


def lex(src: String) raises -> List[Token]:
    var tokens = List[Token]()
    var n = src.byte_length()
    var i = 0
    var text_start = 0

    while i < n:
        var bs = src.as_bytes()
        # Look for {{, {%, or {# at position i.
        if i + 1 < n and bs[i] == UInt8(123):  # '{'
            var c2 = bs[i + 1]
            if c2 == UInt8(123) or c2 == UInt8(37) or c2 == UInt8(35):  # { % #
                # Flush any pending TEXT.
                if i > text_start:
                    tokens.append(Token(TOK_TEXT, String(src[byte=text_start:i])))
                if c2 == UInt8(123):     # {{ ... }}
                    var end = _scan_until(src, i + 2, "}}")
                    tokens.append(Token(TOK_EXPR, String(String(src[byte=i + 2:end]).strip())))
                    i = end + 2
                elif c2 == UInt8(37):    # {% ... %}
                    var end = _scan_until(src, i + 2, "%}")
                    tokens.append(Token(TOK_STMT, String(String(src[byte=i + 2:end]).strip())))
                    i = end + 2
                else:                    # {# ... #}
                    var end = _scan_until(src, i + 2, "#}")
                    tokens.append(Token(TOK_COMMENT, String(src[byte=i + 2:end])))
                    i = end + 2
                text_start = i
                continue
        i += 1

    if n > text_start:
        tokens.append(Token(TOK_TEXT, String(src[byte=text_start:n])))
    return tokens^


# ──────────────────────────────────────────────────────────────────────────
# Expression parser + evaluator.
#
# Grammar (loose):
#   expr     := or_expr
#   or_expr  := and_expr ("or" and_expr)*
#   and_expr := not_expr ("and" not_expr)*
#   not_expr := "not"? cmp
#   cmp      := unary ( (==|!=|<|<=|>|>=) unary )?
#   unary    := primary ("|" filter)*
#   primary  := LITERAL | dotted_name | "(" expr ")"
#   filter   := IDENT ( "(" expr_list ")" )?
# ──────────────────────────────────────────────────────────────────────────

@fieldwise_init
struct ExprParser(Copyable, Movable):
    var bs: List[UInt8]
    var pos: Int


def _peek_ch(p: ExprParser) -> UInt8:
    if p.pos >= len(p.bs):
        return UInt8(0)
    return p.bs[p.pos]


def _eof(p: ExprParser) -> Bool:
    return p.pos >= len(p.bs)


def _is_ws(c: UInt8) -> Bool:
    return c == UInt8(32) or c == UInt8(9) or c == UInt8(10) or c == UInt8(13)


def _is_digit(c: UInt8) -> Bool:
    var v = Int(c)
    return v >= 48 and v <= 57


def _is_alpha(c: UInt8) -> Bool:
    var v = Int(c)
    return (v >= 65 and v <= 90) or (v >= 97 and v <= 122) or v == 95  # _


def _is_alnum(c: UInt8) -> Bool:
    return _is_alpha(c) or _is_digit(c)


def _eat_ws(mut p: ExprParser):
    while not _eof(p) and _is_ws(_peek_ch(p)):
        p.pos += 1


def _starts_with_word(p: ExprParser, kw: String) -> Bool:
    """Match a keyword followed by EOF or a non-alnum char."""
    var kb = kw.as_bytes()
    var kn = len(kb)
    if p.pos + kn > len(p.bs):
        return False
    for i in range(kn):
        if p.bs[p.pos + i] != kb[i]:
            return False
    if p.pos + kn < len(p.bs):
        var c = p.bs[p.pos + kn]
        if _is_alnum(c):
            return False
    return True


def _consume_word(mut p: ExprParser, kw: String) -> Bool:
    if _starts_with_word(p, kw):
        p.pos += kw.byte_length()
        return True
    return False


def _read_ident(mut p: ExprParser) raises -> String:
    _eat_ws(p)
    if _eof(p) or not _is_alpha(_peek_ch(p)):
        raise Error("template: expected identifier")
    var start = p.pos
    while not _eof(p) and _is_alnum(_peek_ch(p)):
        p.pos += 1
    var bytes = List[UInt8]()
    for i in range(start, p.pos):
        bytes.append(p.bs[i])
    return String(unsafe_from_utf8=bytes[:])


def _read_string_literal(mut p: ExprParser) raises -> String:
    var quote = _peek_ch(p)
    p.pos += 1
    var out = List[UInt8]()
    while not _eof(p):
        var c = p.bs[p.pos]
        if c == quote:
            p.pos += 1
            return String(unsafe_from_utf8=out[:])
        if c == UInt8(92) and p.pos + 1 < len(p.bs):  # backslash
            var nxt = p.bs[p.pos + 1]
            if   nxt == UInt8(110): out.append(UInt8(10))
            elif nxt == UInt8(116): out.append(UInt8(9))
            elif nxt == UInt8(114): out.append(UInt8(13))
            elif nxt == UInt8(92): out.append(UInt8(92))
            else: out.append(nxt)
            p.pos += 2
            continue
        out.append(c)
        p.pos += 1
    raise Error("template: unterminated string literal")


def _read_number(mut p: ExprParser) raises -> Value:
    var start = p.pos
    var has_dot = False
    while not _eof(p):
        var c = _peek_ch(p)
        if _is_digit(c):
            p.pos += 1
        elif c == UInt8(46) and not has_dot:  # '.'
            has_dot = True
            p.pos += 1
        else:
            break
    var bytes = List[UInt8]()
    for i in range(start, p.pos):
        bytes.append(p.bs[i])
    var s = String(unsafe_from_utf8=bytes[:])
    if has_dot:
        try:
            return Value.float_(atof(s))
        except:
            raise Error("template: bad float literal '" + s + "'")
    try:
        return Value.int_(atol(s))
    except:
        raise Error("template: bad int literal '" + s + "'")


def _apply_filter(value: Value, name: String, args: List[Value]) raises -> Value:
    """Apply one filter to a value. Filters take the value as the first
    argument (piped), with any explicit args after that.

    Returns a new Value (filters never mutate the input).
    """
    if name == "escape" or name == "e":
        return _filter_escape(value)
    if name == "safe":
        # Marker for the caller — they shouldn't auto-escape.
        # We store the marker by tagging the string in `to_str()` later;
        # for now we just return the original value. The renderer checks
        # for `|safe` in the filter chain separately.
        return value.copy()
    if name == "upper":
        return Value.string(value.to_str().upper())
    if name == "lower":
        return Value.string(value.to_str().lower())
    if name == "length":
        if value.tag == V_LIST:   return Value.int_(len(value.items))
        if value.tag == V_DICT:   return Value.int_(len(value.keys))
        if value.tag == V_STRING: return Value.int_(value.s.byte_length())
        return Value.int_(0)
    if name == "default":
        if len(args) != 1:
            raise Error("template: default(arg) takes exactly one argument")
        if not value.truthy():
            return args[0].copy()
        return value.copy()
    raise Error("template: unknown filter '" + name + "'")


def _filter_escape(value: Value) -> Value:
    """HTML-escape a value, byte-preserving for multi-byte UTF-8.

    NOTE: the obvious-looking `out += chr(Int(c))` is wrong for bytes ≥ 0x80
    — `chr()` interprets its argument as a *codepoint* and re-encodes it
    in UTF-8, so a raw 0xC2 (the leading byte of "·") becomes the two
    bytes of U+00C2 ("Â") and the trailing 0xB7 becomes the two bytes of
    U+00B7 ("·"), corrupting every multi-byte character. Same bug I hit
    in mojo-json's string parser. Fix: accumulate raw UTF-8 bytes in a
    List[UInt8] and convert to String via unsafe_from_utf8 at the end.
    """
    var s = value.to_str()
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var n = len(bs)
    for i in range(n):
        var c = bs[i]
        if   c == UInt8(38):  out.append(UInt8(38));  _append_str(out, String("amp;"))    # &
        elif c == UInt8(60):  out.append(UInt8(38));  _append_str(out, String("lt;"))     # <
        elif c == UInt8(62):  out.append(UInt8(38));  _append_str(out, String("gt;"))     # >
        elif c == UInt8(34):  out.append(UInt8(38));  _append_str(out, String("quot;"))   # "
        elif c == UInt8(39):  out.append(UInt8(38));  _append_str(out, String("#39;"))    # '
        else: out.append(c)
    return Value.string(String(unsafe_from_utf8=out[:]))


def _append_str(mut out: List[UInt8], s: String):
    """Append the raw UTF-8 bytes of `s` to `out`."""
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])


def _eval_primary(mut p: ExprParser, ctx: Value) raises -> Value:
    _eat_ws(p)
    if _eof(p):
        raise Error("template: unexpected end of expression")
    var c = _peek_ch(p)

    # Parenthesized.
    if c == UInt8(40):  # '('
        p.pos += 1
        var v = _eval_or(p, ctx)
        _eat_ws(p)
        if _eof(p) or _peek_ch(p) != UInt8(41):  # ')'
            raise Error("template: expected ')'")
        p.pos += 1
        return v^

    # String literal.
    if c == UInt8(34) or c == UInt8(39):  # " or '
        return Value.string(_read_string_literal(p))

    # Number literal.
    if _is_digit(c):
        return _read_number(p)

    # Keywords / identifier (dotted).
    if _is_alpha(c):
        if _consume_word(p, "true"):  return Value.bool_(True)
        if _consume_word(p, "false"): return Value.bool_(False)
        if _consume_word(p, "none"):  return Value.none()
        # Dotted name resolved against context.
        var name = _read_ident(p)
        var current = ctx.get(name)
        while not _eof(p) and _peek_ch(p) == UInt8(46):  # '.'
            p.pos += 1
            var attr = _read_ident(p)
            current = current.get(attr)
        return current^

    raise Error("template: unexpected character in expression")


def _eval_unary_with_filters(mut p: ExprParser, ctx: Value) raises -> EvalResult:
    """Returns (value, safe_marked). `safe_marked` is true if the filter
    chain ended with `|safe`, telling the caller not to auto-escape."""
    var v = _eval_primary(p, ctx)
    var safe = False
    while True:
        _eat_ws(p)
        if _eof(p) or _peek_ch(p) != UInt8(124):  # '|'
            break
        p.pos += 1
        _eat_ws(p)
        var name = _read_ident(p)
        var args = List[Value]()
        _eat_ws(p)
        if not _eof(p) and _peek_ch(p) == UInt8(40):  # '('
            p.pos += 1
            _eat_ws(p)
            if _eof(p) or _peek_ch(p) != UInt8(41):
                args.append(_eval_or(p, ctx))
                _eat_ws(p)
                while not _eof(p) and _peek_ch(p) == UInt8(44):  # ','
                    p.pos += 1
                    args.append(_eval_or(p, ctx))
                    _eat_ws(p)
            if _eof(p) or _peek_ch(p) != UInt8(41):
                raise Error("template: expected ')' after filter args")
            p.pos += 1
        if name == "safe":
            safe = True
        v = _apply_filter(v, name, args)
    return EvalResult(v^, safe)


def _eval_cmp(mut p: ExprParser, ctx: Value) raises -> Value:
    var lhs_tup = _eval_unary_with_filters(p, ctx)
    var lhs = lhs_tup.value.copy()
    _eat_ws(p)
    if _eof(p):
        return lhs^

    # Two-char first.
    var c0 = _peek_ch(p)
    var c1 = UInt8(0)
    if p.pos + 1 < len(p.bs):
        c1 = p.bs[p.pos + 1]

    var op = String()
    if c0 == UInt8(61) and c1 == UInt8(61): op = "=="; p.pos += 2
    elif c0 == UInt8(33) and c1 == UInt8(61): op = "!="; p.pos += 2
    elif c0 == UInt8(60) and c1 == UInt8(61): op = "<="; p.pos += 2
    elif c0 == UInt8(62) and c1 == UInt8(61): op = ">="; p.pos += 2
    elif c0 == UInt8(60):                     op = "<";  p.pos += 1
    elif c0 == UInt8(62):                     op = ">";  p.pos += 1
    else:
        return lhs^

    var rhs_tup = _eval_unary_with_filters(p, ctx)
    var rhs = rhs_tup.value.copy()
    var result: Bool
    if   op == "==": result = lhs.eq(rhs)
    elif op == "!=": result = not lhs.eq(rhs)
    elif op == "<":  result = lhs.lt(rhs)
    elif op == "<=": result = lhs.lt(rhs) or lhs.eq(rhs)
    elif op == ">":  result = rhs.lt(lhs)
    elif op == ">=": result = rhs.lt(lhs) or lhs.eq(rhs)
    else: raise Error("template: bad comparison op")
    return Value.bool_(result)


def _eval_not(mut p: ExprParser, ctx: Value) raises -> Value:
    _eat_ws(p)
    if _consume_word(p, "not"):
        var inner = _eval_cmp(p, ctx)
        return Value.bool_(not inner.truthy())
    return _eval_cmp(p, ctx)


def _eval_and(mut p: ExprParser, ctx: Value) raises -> Value:
    var lhs = _eval_not(p, ctx)
    while True:
        _eat_ws(p)
        if not _consume_word(p, "and"):
            break
        var rhs = _eval_not(p, ctx)
        lhs = Value.bool_(lhs.truthy() and rhs.truthy())
    return lhs^


def _eval_or(mut p: ExprParser, ctx: Value) raises -> Value:
    var lhs = _eval_and(p, ctx)
    while True:
        _eat_ws(p)
        if not _consume_word(p, "or"):
            break
        var rhs = _eval_and(p, ctx)
        lhs = Value.bool_(lhs.truthy() or rhs.truthy())
    return lhs^


def evaluate(expr: String, ctx: Value) raises -> Value:
    """Parse and evaluate one expression against `ctx`. Top-level entry."""
    var bs = expr.as_bytes()
    var lst = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        lst.append(bs[i])
    var p = ExprParser(lst^, 0)
    var v = _eval_or(p, ctx)
    _eat_ws(p)
    if not _eof(p):
        raise Error("template: trailing input in expression: '" + expr + "'")
    return v^


def evaluate_with_safe(expr: String, ctx: Value) raises -> EvalResult:
    """Same as evaluate(), but returns whether the filter chain ended in
    `|safe` so the renderer can skip auto-escape on the final string."""
    var bs = expr.as_bytes()
    var lst = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        lst.append(bs[i])
    var p = ExprParser(lst^, 0)
    var v = _eval_or(p, ctx)
    _eat_ws(p)
    if not _eof(p):
        raise Error("template: trailing input in expression: '" + expr + "'")
    return EvalResult(v^, _has_safe_filter(expr))


def _has_safe_filter(expr: String) -> Bool:
    """Lightweight check for whether the expression's filter chain
    contains a `|safe` at the top level. Misses pathological cases
    (e.g. nested in a string literal) — good enough for v0.1."""
    # Walk the expression, find unescaped '|' and check the next ident.
    var bs = expr.as_bytes()
    var i = 0
    var in_str = UInt8(0)
    while i < len(bs):
        var c = bs[i]
        if in_str != UInt8(0):
            if c == in_str: in_str = UInt8(0)
            i += 1; continue
        if c == UInt8(34) or c == UInt8(39):
            in_str = c; i += 1; continue
        if c == UInt8(124):  # '|'
            var j = i + 1
            while j < len(bs) and _is_ws(bs[j]):
                j += 1
            # Read filter name.
            var ks = j
            while j < len(bs) and _is_alnum(bs[j]):
                j += 1
            if j - ks == 4:
                if bs[ks] == UInt8(115) and bs[ks+1] == UInt8(97) \
                   and bs[ks+2] == UInt8(102) and bs[ks+3] == UInt8(101):
                    return True
            i = j
            continue
        i += 1
    return False


# ──────────────────────────────────────────────────────────────────────────
# AST + parser for the template body.
#
# Nodes:
#   TextNode    — literal text
#   ExprNode    — {{ expr }}
#   IfNode      — sequence of (cond, body) branches + optional else body
#   ForNode     — for var in expr ... endfor
#
# v0.1 doesn't have blocks/extends/include — the Node taxonomy stays flat.
# ──────────────────────────────────────────────────────────────────────────

comptime N_TEXT: Int = 0
comptime N_EXPR: Int = 1
comptime N_IF:   Int = 2
comptime N_FOR:  Int = 3


struct Node(Copyable, Movable):
    var kind: Int
    var text: String                # for TEXT, the literal body; for EXPR, the expression source

    # IF: parallel arrays of branch conditions + branch bodies.
    var if_conds: List[String]
    var if_bodies: List[List[Node]]
    var if_else: List[Node]
    var if_has_else: Bool

    # FOR: loop variable name, expression, body.
    var for_var: String
    var for_expr: String
    var for_body: List[Node]

    def __init__(out self):
        self.kind = N_TEXT
        self.text = String()
        self.if_conds = List[String]()
        self.if_bodies = List[List[Node]]()
        self.if_else = List[Node]()
        self.if_has_else = False
        self.for_var = String()
        self.for_expr = String()
        self.for_body = List[Node]()

    @staticmethod
    def text_node(s: String) -> Node:
        var n = Node(); n.kind = N_TEXT; n.text = s; return n^

    @staticmethod
    def expr_node(src: String) -> Node:
        var n = Node(); n.kind = N_EXPR; n.text = src; return n^


@fieldwise_init
struct Parser(Copyable, Movable):
    var tokens: List[Token]
    var pos: Int


def _stmt_starts(s: String, prefix: String) -> Bool:
    """A statement body s starts with prefix (followed by space/EOF)."""
    if s == prefix: return True
    if not s.startswith(prefix): return False
    var pn = prefix.byte_length()
    return s.byte_length() == pn or s.as_bytes()[pn] == UInt8(32)


def parse_template(tokens: List[Token]) raises -> List[Node]:
    var p = Parser(tokens.copy(), 0)
    return _parse_block(p, List[String]())


def _parse_block(mut p: Parser, end_markers: List[String]) raises -> List[Node]:
    """Parse nodes until we hit a stmt token whose body starts with one of
    `end_markers` (we leave that token in place for the caller)."""
    var nodes = List[Node]()
    while p.pos < len(p.tokens):
        var tok = p.tokens[p.pos].copy()
        if tok.kind == TOK_TEXT:
            nodes.append(Node.text_node(tok.body))
            p.pos += 1
            continue
        if tok.kind == TOK_COMMENT:
            p.pos += 1
            continue
        if tok.kind == TOK_EXPR:
            nodes.append(Node.expr_node(tok.body))
            p.pos += 1
            continue
        # STMT
        var body = tok.body
        for m in end_markers:
            if _stmt_starts(body, m):
                return nodes^
        if _stmt_starts(body, "if"):
            nodes.append(_parse_if(p))
        elif _stmt_starts(body, "for"):
            nodes.append(_parse_for(p))
        else:
            raise Error("template: unknown statement '" + body + "'")
    return nodes^


def _parse_if(mut p: Parser) raises -> Node:
    var ifn = Node()
    ifn.kind = N_IF

    # The current token is "if <cond>".
    var first = p.tokens[p.pos].body
    var cond_str = String(String(first[byte=2:]).strip())  # drop "if"
    p.pos += 1
    ifn.if_conds.append(cond_str^)

    var enders = List[String]()
    enders.append(String("elif"))
    enders.append(String("else"))
    enders.append(String("endif"))

    ifn.if_bodies.append(_parse_block(p, enders))

    while p.pos < len(p.tokens):
        var body = p.tokens[p.pos].body
        if _stmt_starts(body, "elif"):
            var c = String(String(body[byte=4:]).strip())
            p.pos += 1
            ifn.if_conds.append(c^)
            ifn.if_bodies.append(_parse_block(p, enders))
        elif _stmt_starts(body, "else"):
            p.pos += 1
            var only_end = List[String]()
            only_end.append(String("endif"))
            ifn.if_else = _parse_block(p, only_end)
            ifn.if_has_else = True
        elif _stmt_starts(body, "endif"):
            p.pos += 1
            return ifn^
        else:
            raise Error("template: expected elif/else/endif")
    raise Error("template: missing endif")


def _parse_for(mut p: Parser) raises -> Node:
    """Parse `for VAR in EXPR` ... `endfor`."""
    var forn = Node()
    forn.kind = N_FOR

    var head = p.tokens[p.pos].body  # "for VAR in EXPR"
    var after_for = String(String(head[byte=3:]).strip())  # drop "for"
    var in_pos = after_for.find(" in ")
    if in_pos < 0:
        raise Error("template: bad 'for' syntax — expected 'for VAR in EXPR'")
    forn.for_var  = String(String(after_for[byte=:in_pos]).strip())
    forn.for_expr = String(String(after_for[byte=in_pos + 4:]).strip())
    p.pos += 1

    var enders = List[String]()
    enders.append(String("endfor"))
    forn.for_body = _parse_block(p, enders)

    if p.pos >= len(p.tokens) or not _stmt_starts(p.tokens[p.pos].body, "endfor"):
        raise Error("template: missing endfor")
    p.pos += 1
    return forn^


# ──────────────────────────────────────────────────────────────────────────
# Template handle + render.
# ──────────────────────────────────────────────────────────────────────────

struct Template(Copyable, Movable):
    var nodes: List[Node]

    def __init__(out self, source: String) raises:
        var toks = lex(source)
        self.nodes = parse_template(toks)


def render(t: Template, ctx: Value) raises -> String:
    var out = String()
    _render_nodes(t.nodes, ctx, out)
    return out^


def _render_nodes(nodes: List[Node], ctx: Value, mut out: String) raises:
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.kind == N_TEXT:
            out += n.text
        elif n.kind == N_EXPR:
            var pair = evaluate_with_safe(n.text, ctx)
            if pair.safe:
                out += pair.value.to_str()
            else:
                # Auto-escape the rendered string.
                var esc = _filter_escape(Value.string(pair.value.to_str()))
                out += esc.s
        elif n.kind == N_IF:
            var taken = False
            for b in range(len(n.if_conds)):
                var cond = evaluate(n.if_conds[b], ctx)
                if cond.truthy():
                    _render_nodes(n.if_bodies[b], ctx, out)
                    taken = True
                    break
            if not taken and n.if_has_else:
                _render_nodes(n.if_else, ctx, out)
        elif n.kind == N_FOR:
            var iter_val = evaluate(n.for_expr, ctx)
            if iter_val.tag == V_LIST:
                for it in range(len(iter_val.items)):
                    var loop_ctx = ctx.copy()
                    loop_ctx.set(n.for_var, iter_val.items[it].copy())
                    _render_nodes(n.for_body, loop_ctx, out)
            elif iter_val.tag == V_DICT:
                for it in range(len(iter_val.keys)):
                    var loop_ctx = ctx.copy()
                    loop_ctx.set(n.for_var, Value.string(iter_val.keys[it]))
                    _render_nodes(n.for_body, loop_ctx, out)
            # Non-iterable: silently render nothing (Jinja behavior is
            # similar — undefined iters produce empty output).
