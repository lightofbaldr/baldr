"""Phase 2.4 — validation tests."""

from std.collections import List

from baldr.json import JsonValue, parse as json_parse
from baldr.request import Request
from baldr.response import Response
from baldr.validation import (
    FieldError, ValidationResult, Validator, validate_json,
    Required, StringLength, FieldType,
)


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

    # ── Required ───────────────────────────────────────────────────────
    var obj = json_parse(String("{\"name\":\"ada\",\"age\":30}"))
    var req_ok = Required(String("name")).validate(obj)
    r.check("Required present -> ok", req_ok.ok)

    var req_missing = Required(String("nope")).validate(obj)
    r.check("Required absent -> not ok", not req_missing.ok)
    r.check("Required absent -> 1 error", len(req_missing.errors) == 1)
    r.check("Required code 'required'", req_missing.errors[0].code == "required")

    var obj2 = json_parse(String("{\"x\":null}"))
    var req_null = Required(String("x")).validate(obj2)
    r.check("Required null -> not ok", not req_null.ok)

    # ── StringLength ───────────────────────────────────────────────────
    var sl_ok = StringLength(String("name"), 1, 100).validate(obj)
    r.check("StringLength ok (3 chars, 1-100)", sl_ok.ok)

    var sl_short = StringLength(String("name"), 10, 100).validate(obj)
    r.check("StringLength too short", not sl_short.ok)
    r.check("StringLength code 'min_length'", sl_short.errors[0].code == "min_length")

    var obj3 = json_parse(String("{\"s\":\"this is way too long\"}"))
    var sl_long = StringLength(String("s"), 1, 5).validate(obj3)
    r.check("StringLength too long", not sl_long.ok)
    r.check("StringLength code 'max_length'", sl_long.errors[0].code == "max_length")

    var sl_absent = StringLength(String("missing"), 1, 100).validate(obj)
    r.check("StringLength absent -> ok (skip)", sl_absent.ok)

    # ── FieldType ──────────────────────────────────────────────────────
    var ft_ok = FieldType(String("name"), String("string")).validate(obj)
    r.check("FieldType string ok", ft_ok.ok)
    var ft_bad = FieldType(String("name"), String("number")).validate(obj)
    r.check("FieldType wrong -> not ok", not ft_bad.ok)
    var ft_age = FieldType(String("age"), String("number")).validate(obj)
    r.check("FieldType number ok", ft_age.ok)
    var ft_absent = FieldType(String("missing"), String("string")).validate(obj)
    r.check("FieldType absent -> ok (skip)", ft_absent.ok)

    # ── comptime chain merges errors ───────────────────────────────────
    var chained = validate_json[ Required, StringLength, FieldType ](
        obj3,
        Required(String("name")),                              # fail (absent)
        StringLength(String("s"), 1, 5),                       # fail (too long)
        FieldType(String("s"), String("string")),              # ok
    )
    r.check("chain not ok (2 failures)", not chained.ok)
    r.check("chain merges 2 errors", len(chained.errors) == 2)

    # ── ValidationResult.to_response -> 422 JSON ───────────────────────
    var vr = ValidationResult()
    vr.ok = False
    vr.errors.append(FieldError(String("name"), String("required"), String("name is required")))
    var resp = vr.to_response()
    r.check("to_response status 422", resp.status == 422)
    var ctype = String()
    for i in range(len(resp.headers)):
        if resp.headers[i].key == "Content-Type":
            ctype = resp.headers[i].value
    r.check("to_response content-type json", ctype == "application/json; charset=utf-8")
    var body = String()
    for i in range(len(resp.body)):
        body += chr(Int(resp.body[i]))
    r.check("to_response body has ok:false", body.find(String("\"ok\":false")) >= 0)
    r.check("to_response body has errors array", body.find(String("\"errors\"")) >= 0)
    r.check("to_response body has field name", body.find(String("name")) >= 0)

    # ── Request.validate (full path: body -> json -> validators) ───────
    var req = Request(String("POST"), String("/"), String(), String(), Dict[String, String]())
    req.body = String("{\"name\":\"\",\"age\":\"not-a-number\"}")
    var result = req.validate(
        Required(String("name")),
        StringLength(String("name"), 1, 100),
        FieldType(String("age"), String("number")),
    )
    r.check("req.validate not ok", not result.ok)
    r.check("req.validate 2 errors (empty name + age not number)", len(result.errors) == 2)

    var req2 = Request(String("POST"), String("/"), String(), String(), Dict[String, String]())
    req2.body = String("{\"name\":\"ada\",\"age\":30}")
    var result2 = req2.validate(
        Required(String("name")),
        StringLength(String("name"), 1, 100),
        FieldType(String("age"), String("number")),
    )
    r.check("req.validate all ok", result2.ok)

    r.summary()
