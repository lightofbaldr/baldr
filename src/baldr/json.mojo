"""mojo-json — pure-Mojo JSON parser and emitter.

Single self-contained module. No external dependencies. Designed as
the data-format building block for the rest of the lightofbaldr Mojo
OSS stack — `mojo-serve` for JSON responses, future `mojo-redis` for
value serialization, config files, etc.

Public API:

    var v = parse(' {"a": [1, 2.5, "x"], "b": null} ')   # JsonValue
    var s = dumps(v)                                      # String
    var s_pretty = dumps_pretty(v, indent=2)

    # Tag inspection:
    if v.is_object():
        var x = v.get("a")
        if x.is_array():
            for i in range(x.array_len()):
                print(dumps(x.array_at(i)))

    # Constructors:
    var null_v = JsonValue.from_null()
    var b      = JsonValue.from_bool(True)
    var n      = JsonValue.from_number(3.14)
    var s_v    = JsonValue.from_string("hello")
    var arr    = JsonValue.from_array(List[JsonValue]())
    var obj    = JsonValue.from_object()

Spec coverage:
- null / true / false / numbers / strings / arrays / objects
- All escape sequences: \\\\ \\" \\/ \\b \\f \\n \\r \\t and \\uXXXX
- Numbers: integers, decimals, exponents, negative sign
- Surrogate pairs in \\uXXXX (high + low → UTF-8)
- Whitespace per RFC 8259 (space, tab, LF, CR)

What v0.1 does NOT do:
- BigInt preservation — every number becomes Float64. (Lossy past 2**53.)
- Streaming / SAX parser. We parse the whole thing into memory.
- Duplicate-key handling — last value wins, no warning.
- Pretty-print line-wrap rules; `dumps_pretty` is the simplest possible.
"""

from std.collections.string import StringSlice


# Tag values for the JsonValue tagged union.
comptime JSON_NULL: Int = 0
comptime JSON_BOOL: Int = 1
comptime JSON_NUMBER: Int = 2
comptime JSON_STRING: Int = 3
comptime JSON_ARRAY: Int = 4
comptime JSON_OBJECT: Int = 5


# --------------------------------------------------------------------------
# JsonValue — tagged-union value type. Mojo doesn't have first-class sum
# types yet, so we use a tag plus storage fields. Only the field selected
# by `tag` is meaningful; the others hold default values to keep the
# struct trivially Copyable / Movable.
# --------------------------------------------------------------------------

struct JsonValue(Copyable, Movable):
    var tag: Int
    var bool_val: Bool
    var number_val: Float64
    var string_val: String
    var array_val: List[JsonValue]
    var object_keys: List[String]
    var object_values: List[JsonValue]

    def __init__(out self):
        self.tag = JSON_NULL
        self.bool_val = False
        self.number_val = 0.0
        self.string_val = String()
        self.array_val = List[JsonValue]()
        self.object_keys = List[String]()
        self.object_values = List[JsonValue]()

    # ── Constructors ────────────────────────────────────────────────
    @staticmethod
    def from_null() -> JsonValue:
        return JsonValue()

    @staticmethod
    def from_bool(b: Bool) -> JsonValue:
        var v = JsonValue()
        v.tag = JSON_BOOL
        v.bool_val = b
        return v^

    @staticmethod
    def from_number(n: Float64) -> JsonValue:
        var v = JsonValue()
        v.tag = JSON_NUMBER
        v.number_val = n
        return v^

    @staticmethod
    def from_int(n: Int) -> JsonValue:
        return JsonValue.from_number(Float64(n))

    @staticmethod
    def from_string(s: String) -> JsonValue:
        var v = JsonValue()
        v.tag = JSON_STRING
        v.string_val = s
        return v^

    @staticmethod
    def from_array(var xs: List[JsonValue]) -> JsonValue:
        var v = JsonValue()
        v.tag = JSON_ARRAY
        v.array_val = xs^
        return v^

    @staticmethod
    def from_object() -> JsonValue:
        var v = JsonValue()
        v.tag = JSON_OBJECT
        return v^

    # ── Tag predicates ──────────────────────────────────────────────
    def is_null(self) -> Bool: return self.tag == JSON_NULL
    def is_bool(self) -> Bool: return self.tag == JSON_BOOL
    def is_number(self) -> Bool: return self.tag == JSON_NUMBER
    def is_string(self) -> Bool: return self.tag == JSON_STRING
    def is_array(self) -> Bool: return self.tag == JSON_ARRAY
    def is_object(self) -> Bool: return self.tag == JSON_OBJECT

    # ── Array helpers ───────────────────────────────────────────────
    def array_len(self) -> Int: return len(self.array_val)

    def array_at(self, i: Int) -> JsonValue:
        return self.array_val[i].copy()

    def array_push(mut self, var v: JsonValue):
        self.array_val.append(v^)

    # ── Object helpers ──────────────────────────────────────────────
    def object_len(self) -> Int: return len(self.object_keys)

    def has(self, key: String) -> Bool:
        for i in range(len(self.object_keys)):
            if self.object_keys[i] == key:
                return True
        return False

    def get(self, key: String) -> JsonValue:
        """Return value for `key`, or null if missing. Last write wins."""
        for i in range(len(self.object_keys) - 1, -1, -1):
            if self.object_keys[i] == key:
                return self.object_values[i].copy()
        return JsonValue()  # null

    def set(mut self, key: String, var v: JsonValue):
        # Overwrite if present, else append. Linear scan; fine for v0.1
        # — typical JSON object sizes are small enough that a hash map
        # would be more code than it's worth.
        for i in range(len(self.object_keys)):
            if self.object_keys[i] == key:
                self.object_values[i] = v^
                return
        self.object_keys.append(key)
        self.object_values.append(v^)


# --------------------------------------------------------------------------
# Parser — recursive-descent on the JSON grammar in RFC 8259.
# --------------------------------------------------------------------------

struct _Parser:
    var src: List[UInt8]
    var pos: Int

    def __init__(out self, s: String):
        var b = s.as_bytes()
        var lst = List[UInt8](capacity=len(b))
        for i in range(len(b)):
            lst.append(b[i])
        self.src = lst^
        self.pos = 0


def _is_ws(c: UInt8) -> Bool:
    return c == UInt8(32) or c == UInt8(9) or c == UInt8(10) or c == UInt8(13)


def _skip_ws(mut p: _Parser):
    while p.pos < len(p.src) and _is_ws(p.src[p.pos]):
        p.pos += 1


def _peek(p: _Parser) -> UInt8:
    return p.src[p.pos]


def _expect(mut p: _Parser, c: UInt8) raises:
    if p.pos >= len(p.src) or p.src[p.pos] != c:
        raise Error("json: expected byte " + String(Int(c)) + " at offset " + String(p.pos))
    p.pos += 1


def _expect_literal(mut p: _Parser, lit: String) raises:
    var b = lit.as_bytes()
    if p.pos + len(b) > len(p.src):
        raise Error("json: unexpected end of input while parsing literal '" + lit + "'")
    for i in range(len(b)):
        if p.src[p.pos + i] != b[i]:
            raise Error("json: expected literal '" + lit + "' at offset " + String(p.pos))
    p.pos += len(b)


def _hex_nibble(c: UInt8) raises -> Int:
    var v = Int(c)
    if v >= 48 and v <= 57:  return v - 48
    if v >= 65 and v <= 70:  return v - 55
    if v >= 97 and v <= 102: return v - 87
    raise Error("json: bad hex digit '" + chr(v) + "'")


def _append_codepoint(mut out: List[UInt8], cp: Int):
    """Encode a Unicode codepoint as raw UTF-8 bytes into `out`.

    We append raw bytes (not codepoints) because `chr()` would re-encode
    each byte as a UTF-8 codepoint, double-encoding the sequence we're
    constructing. The parser collects into a byte buffer and converts to
    String once at the end via `String(unsafe_from_utf8=...)`.
    """
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _parse_string(mut p: _Parser) raises -> String:
    _expect(p, UInt8(34))  # opening "
    # Collect raw UTF-8 bytes; convert to String once at the end so we
    # don't double-encode (chr() interprets its argument as a codepoint,
    # which would re-encode bytes we've already computed).
    var bytes = List[UInt8]()
    while p.pos < len(p.src):
        var c = p.src[p.pos]
        if c == UInt8(34):  # closing "
            p.pos += 1
            return String(unsafe_from_utf8=bytes[:])
        if c == UInt8(92):  # backslash
            if p.pos + 1 >= len(p.src):
                raise Error("json: unterminated escape")
            var esc = p.src[p.pos + 1]
            p.pos += 2
            if   esc == UInt8(34):  bytes.append(UInt8(34))   # "
            elif esc == UInt8(92):  bytes.append(UInt8(92))   # \
            elif esc == UInt8(47):  bytes.append(UInt8(47))   # /
            elif esc == UInt8(98):  bytes.append(UInt8(8))    # \b
            elif esc == UInt8(102): bytes.append(UInt8(12))   # \f
            elif esc == UInt8(110): bytes.append(UInt8(10))   # \n
            elif esc == UInt8(114): bytes.append(UInt8(13))   # \r
            elif esc == UInt8(116): bytes.append(UInt8(9))    # \t
            elif esc == UInt8(117):  # \uXXXX
                if p.pos + 4 > len(p.src):
                    raise Error("json: truncated \\u escape")
                var hi = (_hex_nibble(p.src[p.pos]) << 12) \
                       | (_hex_nibble(p.src[p.pos + 1]) << 8) \
                       | (_hex_nibble(p.src[p.pos + 2]) << 4) \
                       |  _hex_nibble(p.src[p.pos + 3])
                p.pos += 4
                # Surrogate pair?
                if hi >= 0xD800 and hi <= 0xDBFF:
                    if (p.pos + 6 > len(p.src)
                        or p.src[p.pos] != UInt8(92)
                        or p.src[p.pos + 1] != UInt8(117)):
                        raise Error("json: expected low-surrogate \\u after high-surrogate")
                    p.pos += 2
                    var lo = (_hex_nibble(p.src[p.pos]) << 12) \
                           | (_hex_nibble(p.src[p.pos + 1]) << 8) \
                           | (_hex_nibble(p.src[p.pos + 2]) << 4) \
                           |  _hex_nibble(p.src[p.pos + 3])
                    p.pos += 4
                    if lo < 0xDC00 or lo > 0xDFFF:
                        raise Error("json: invalid low-surrogate")
                    var cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                    _append_codepoint(bytes, cp)
                else:
                    _append_codepoint(bytes, hi)
            else:
                raise Error("json: invalid escape '\\" + chr(Int(esc)) + "'")
        else:
            bytes.append(c)
            p.pos += 1
    raise Error("json: unterminated string")


def _parse_number(mut p: _Parser) raises -> Float64:
    var start = p.pos
    # Optional minus
    if p.pos < len(p.src) and p.src[p.pos] == UInt8(45):
        p.pos += 1
    # Integer part
    while p.pos < len(p.src):
        var c = p.src[p.pos]
        if c >= UInt8(48) and c <= UInt8(57):
            p.pos += 1
        else:
            break
    # Fraction
    if p.pos < len(p.src) and p.src[p.pos] == UInt8(46):
        p.pos += 1
        while p.pos < len(p.src):
            var c = p.src[p.pos]
            if c >= UInt8(48) and c <= UInt8(57):
                p.pos += 1
            else:
                break
    # Exponent
    if p.pos < len(p.src) and (p.src[p.pos] == UInt8(101) or p.src[p.pos] == UInt8(69)):
        p.pos += 1
        if p.pos < len(p.src) and (p.src[p.pos] == UInt8(43) or p.src[p.pos] == UInt8(45)):
            p.pos += 1
        while p.pos < len(p.src):
            var c = p.src[p.pos]
            if c >= UInt8(48) and c <= UInt8(57):
                p.pos += 1
            else:
                break

    var num_str = String()
    for i in range(start, p.pos):
        num_str += chr(Int(p.src[i]))
    try:
        return atof(num_str)
    except:
        raise Error("json: bad number '" + num_str + "'")


def _parse_value(mut p: _Parser) raises -> JsonValue:
    _skip_ws(p)
    if p.pos >= len(p.src):
        raise Error("json: unexpected end of input")
    var c = p.src[p.pos]
    if c == UInt8(123):           # '{'
        return _parse_object(p)
    elif c == UInt8(91):          # '['
        return _parse_array(p)
    elif c == UInt8(34):          # '"'
        return JsonValue.from_string(_parse_string(p))
    elif c == UInt8(116):         # 't' rue
        _expect_literal(p, "true")
        return JsonValue.from_bool(True)
    elif c == UInt8(102):         # 'f' alse
        _expect_literal(p, "false")
        return JsonValue.from_bool(False)
    elif c == UInt8(110):         # 'n' ull
        _expect_literal(p, "null")
        return JsonValue.from_null()
    elif c == UInt8(45) or (c >= UInt8(48) and c <= UInt8(57)):
        return JsonValue.from_number(_parse_number(p))
    raise Error("json: unexpected byte " + String(Int(c)) + " at offset " + String(p.pos))


def _parse_array(mut p: _Parser) raises -> JsonValue:
    _expect(p, UInt8(91))  # '['
    var xs = List[JsonValue]()
    _skip_ws(p)
    if p.pos < len(p.src) and p.src[p.pos] == UInt8(93):  # ']'
        p.pos += 1
        return JsonValue.from_array(xs^)
    while True:
        xs.append(_parse_value(p))
        _skip_ws(p)
        if p.pos >= len(p.src):
            raise Error("json: unterminated array")
        if p.src[p.pos] == UInt8(44):  # ','
            p.pos += 1
            continue
        if p.src[p.pos] == UInt8(93):  # ']'
            p.pos += 1
            return JsonValue.from_array(xs^)
        raise Error("json: expected ',' or ']' in array")


def _parse_object(mut p: _Parser) raises -> JsonValue:
    _expect(p, UInt8(123))  # '{'
    var obj = JsonValue.from_object()
    _skip_ws(p)
    if p.pos < len(p.src) and p.src[p.pos] == UInt8(125):  # '}'
        p.pos += 1
        return obj^
    while True:
        _skip_ws(p)
        var key = _parse_string(p)
        _skip_ws(p)
        _expect(p, UInt8(58))  # ':'
        var value = _parse_value(p)
        obj.set(key, value^)
        _skip_ws(p)
        if p.pos >= len(p.src):
            raise Error("json: unterminated object")
        if p.src[p.pos] == UInt8(44):  # ','
            p.pos += 1
            continue
        if p.src[p.pos] == UInt8(125):  # '}'
            p.pos += 1
            return obj^
        raise Error("json: expected ',' or '}' in object")


def parse(s: String) raises -> JsonValue:
    """Parse a JSON document into a JsonValue tree."""
    var p = _Parser(s)
    var v = _parse_value(p)
    _skip_ws(p)
    if p.pos != len(p.src):
        raise Error("json: trailing data after document at offset " + String(p.pos))
    return v^


# --------------------------------------------------------------------------
# Emitter — round-trip via dumps()
# --------------------------------------------------------------------------

def _escape_string(s: String) -> String:
    """Produce a quoted JSON string literal from a raw String."""
    var out = String("\"")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var ci = Int(c)
        if c == UInt8(34):
            out += "\\\""
        elif c == UInt8(92):
            out += "\\\\"
        elif c == UInt8(8):
            out += "\\b"
        elif c == UInt8(9):
            out += "\\t"
        elif c == UInt8(10):
            out += "\\n"
        elif c == UInt8(12):
            out += "\\f"
        elif c == UInt8(13):
            out += "\\r"
        elif ci < 0x20:
            # Control character — emit as \uXXXX.
            out += "\\u00"
            var hi = ci >> 4
            var lo = ci & 0xF
            out += chr(48 + hi) if hi < 10 else chr(87 + hi)
            out += chr(48 + lo) if lo < 10 else chr(87 + lo)
        else:
            out += chr(ci)
    out += "\""
    return out^


def _emit_number(n: Float64) -> String:
    """Render a Float64 as JSON. If it's an exact integer we drop the
    trailing ".0" to match what most JSON consumers expect."""
    var s = String(n)
    # Strip trailing ".0" for exact integers in normal range.
    if s.endswith(".0"):
        return String(s[byte=:s.byte_length() - 2])
    return s^


def _emit(v: JsonValue, mut out: String):
    if v.tag == JSON_NULL:
        out += "null"
    elif v.tag == JSON_BOOL:
        out += "true" if v.bool_val else "false"
    elif v.tag == JSON_NUMBER:
        out += _emit_number(v.number_val)
    elif v.tag == JSON_STRING:
        out += _escape_string(v.string_val)
    elif v.tag == JSON_ARRAY:
        out += "["
        for i in range(len(v.array_val)):
            if i > 0:
                out += ","
            _emit(v.array_val[i], out)
        out += "]"
    elif v.tag == JSON_OBJECT:
        out += "{"
        for i in range(len(v.object_keys)):
            if i > 0:
                out += ","
            out += _escape_string(v.object_keys[i])
            out += ":"
            _emit(v.object_values[i], out)
        out += "}"


def dumps(v: JsonValue) -> String:
    """Serialize a JsonValue to a compact JSON string."""
    var out = String()
    _emit(v, out)
    return out^


def _emit_pretty(v: JsonValue, mut out: String, depth: Int, indent: Int):
    if v.tag == JSON_ARRAY:
        if len(v.array_val) == 0:
            out += "[]"
            return
        out += "[\n"
        for i in range(len(v.array_val)):
            for _ in range((depth + 1) * indent):
                out += " "
            _emit_pretty(v.array_val[i], out, depth + 1, indent)
            if i < len(v.array_val) - 1:
                out += ","
            out += "\n"
        for _ in range(depth * indent):
            out += " "
        out += "]"
    elif v.tag == JSON_OBJECT:
        if len(v.object_keys) == 0:
            out += "{}"
            return
        out += "{\n"
        for i in range(len(v.object_keys)):
            for _ in range((depth + 1) * indent):
                out += " "
            out += _escape_string(v.object_keys[i])
            out += ": "
            _emit_pretty(v.object_values[i], out, depth + 1, indent)
            if i < len(v.object_keys) - 1:
                out += ","
            out += "\n"
        for _ in range(depth * indent):
            out += " "
        out += "}"
    else:
        _emit(v, out)


def dumps_pretty(v: JsonValue, indent: Int = 2) -> String:
    """Serialize a JsonValue with newlines and indentation."""
    var out = String()
    _emit_pretty(v, out, 0, indent)
    return out^
