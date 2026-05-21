"""Smoke + round-trip tests for mojo-json.

Single-file standalone driver. Mojo doesn't surface unit-test discovery
for stand-alone OSS packages cleanly yet, so we just build it as a
binary and run it. Exit code is non-zero on first failure.
"""

from baldr.json import (
    JsonValue, parse, dumps, dumps_pretty,
    JSON_NULL, JSON_BOOL, JSON_NUMBER, JSON_STRING, JSON_ARRAY, JSON_OBJECT,
)


# Mojo 1.0 disallows module-level mutables, so counters live in a runner
# struct passed by reference through the test functions.
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
        print("  got: ", got)
        print("  want:", want)


def expect_true(mut r: Runner, name: String, cond: Bool):
    r.total += 1
    if cond:
        print("[ok]", name)
    else:
        r.failures += 1
        print("[FAIL]", name)


def test_primitives(mut r: Runner) raises:
    expect_true(r, "parse null is_null",     parse("null").is_null())
    expect_true(r, "parse true is_bool",     parse("true").is_bool())
    expect_true(r, "parse false is_bool",    parse("false").is_bool())
    expect_true(r, "parse 42 is_number",     parse("42").is_number())
    expect_true(r, "parse \"x\" is_string",  parse("\"x\"").is_string())
    expect_true(r, "parse [] is_array",      parse("[]").is_array())
    expect_true(r, "parse {} is_object",     parse("{}").is_object())

    expect_eq(r, "dumps null",  dumps(JsonValue.from_null()),       String("null"))
    expect_eq(r, "dumps true",  dumps(JsonValue.from_bool(True)),   String("true"))
    expect_eq(r, "dumps 42",    dumps(JsonValue.from_number(42.0)), String("42"))
    expect_eq(r, "dumps 3.14",  dumps(JsonValue.from_number(3.14)), String("3.14"))
    expect_eq(r, "dumps \"x\"", dumps(JsonValue.from_string("x")),  String("\"x\""))


def test_strings_with_escapes(mut r: Runner) raises:
    var raw = "\"\\\"\\\\/\\b\\f\\n\\r\\tend\""
    var v = parse(raw)
    expect_true(r, "escaped string is_string", v.is_string())
    expect_true(r, "escape decode length", v.string_val.byte_length() == 11)
    var dumped = dumps(v)
    var v2 = parse(dumped)
    expect_true(r, "escape round-trip equal", v.string_val == v2.string_val)


def test_unicode_escape(mut r: Runner) raises:
    var v = parse("\"caf\\u00e9\"")
    expect_true(r, "unicode escape is_string", v.is_string())
    # é is 2 UTF-8 bytes, plus "caf" = 5 bytes total.
    expect_true(r, "unicode escape length", v.string_val.byte_length() == 5)


def test_surrogate_pair(mut r: Runner) raises:
    var v = parse("\"\\uD83D\\uDE00\"")
    expect_true(r, "surrogate pair is_string", v.is_string())
    # The emoji is 4 UTF-8 bytes.
    expect_true(r, "surrogate pair length", v.string_val.byte_length() == 4)


def test_numbers(mut r: Runner) raises:
    expect_true(r, "integer parse",     parse("0").number_val == 0.0)
    expect_true(r, "negative parse",    parse("-7").number_val == -7.0)
    expect_true(r, "decimal parse",     parse("3.14").number_val == 3.14)
    expect_true(r, "exponent parse",    parse("1e3").number_val == 1000.0)
    expect_true(r, "neg exp parse",     parse("1.5e-2").number_val == 0.015)


def test_arrays(mut r: Runner) raises:
    var v = parse("[1, 2, 3, \"x\", null, true]")
    expect_true(r, "array length 6", v.array_len() == 6)
    expect_true(r, "array[0] = 1",    v.array_at(0).number_val == 1.0)
    expect_true(r, "array[3] = x",    v.array_at(3).string_val == "x")
    expect_true(r, "array[4] is_null", v.array_at(4).is_null())
    expect_true(r, "array[5] = true",  v.array_at(5).bool_val == True)


def test_objects(mut r: Runner) raises:
    var v = parse("{\"name\": \"adam\", \"age\": 38, \"nested\": {\"x\": [1, 2]}}")
    expect_true(r, "object has name",   v.has("name"))
    expect_true(r, "object name == adam", v.get("name").string_val == "adam")
    expect_true(r, "object age == 38",   v.get("age").number_val == 38.0)
    var nested = v.get("nested")
    expect_true(r, "nested is_object",   nested.is_object())
    var arr = nested.get("x")
    expect_true(r, "nested.x is_array",  arr.is_array())
    expect_true(r, "nested.x[1] = 2",    arr.array_at(1).number_val == 2.0)


def test_whitespace(mut r: Runner) raises:
    var v = parse("  \n  [ \t 1 , \r 2 ]  ")
    expect_true(r, "whitespace tolerant", v.array_len() == 2)


def test_round_trip(mut r: Runner) raises:
    var src = "{\"a\":[1,2.5,\"x\",null,true,false],\"b\":{\"nested\":\"yes\"}}"
    var v = parse(src)
    var out = dumps(v)
    expect_eq(r, "round-trip compact", out, String(src))


def test_pretty(mut r: Runner) raises:
    var v = parse("{\"a\":[1,2],\"b\":true}")
    var pretty = dumps_pretty(v, indent=2)
    expect_true(r, "pretty contains newline", pretty.find("\n") >= 0)
    expect_true(r, "pretty contains indent",  pretty.find("  ") >= 0)
    var v2 = parse(pretty)
    expect_true(r, "pretty round-trips",      v2.get("b").bool_val == True)


def test_errors(mut r: Runner):
    var caught: Bool = False
    try:
        _ = parse("[1, 2,")  # unterminated
    except:
        caught = True
    expect_true(r, "unterminated array raises", caught)

    caught = False
    try:
        _ = parse("{\"a\": ")
    except:
        caught = True
    expect_true(r, "incomplete object raises", caught)

    caught = False
    try:
        _ = parse("nope")
    except:
        caught = True
    expect_true(r, "garbage literal raises", caught)


def main() raises:
    var r = Runner()
    test_primitives(r)
    test_strings_with_escapes(r)
    test_unicode_escape(r)
    test_surrogate_pair(r)
    test_numbers(r)
    test_arrays(r)
    test_objects(r)
    test_whitespace(r)
    test_round_trip(r)
    test_pretty(r)
    test_errors(r)

    print("---")
    print(String(r.total - r.failures), "/", String(r.total), "passed")
    if r.failures > 0:
        print("FAILED:", r.failures)
        raise Error("test failures: " + String(r.failures))
