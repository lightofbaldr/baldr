"""baldr.validation — declarative request validation -> 422.

Phase 2.4 — validation + JSON binding.

Replaces hand-rolled `try: req.json() except: 400` with a declarative layer
that produces structured 422 responses. The shapes follow the design-patterns
research:

  - `FieldError(field, code, message)` — one problem on one field.
  - `ValidationResult(errors, ok)` with `to_response()` -> 422 JSON
    `{"ok":false,"errors":[...]}`.
  - `Validator` trait: `validate(self, value) -> ValidationResult`. Non-mut
    `self` so it composes through the comptime-variadic `validate[*Vs]`
    runner (same constraint as the middleware chain — mutating methods
    can't be dispatched on variadic rvalues in Mojo 1.0).
  - Built-in validators: `Required`, `StringLength`, `FieldType`.
  - `validate_json[*Vs](value, *vs)` runs a comptime chain and merges errors.

`Request.validate[*Vs](self, *vs)` is the convenience entry point: it parses
the body as JSON and runs the validators. Usage:

    var result = req.validate(Required("name"), StringLength("name", 1, 100))
    if not result.ok:
        return result.to_response()
"""

from std.collections import List

from .json import JsonValue, dumps as json_dumps
from .response import Response, Header


# ── Result types ──────────────────────────────────────────────────────────
struct FieldError(Copyable, Movable):
    var field: String
    var code: String
    var message: String

    def __init__(out self, field: String, code: String, message: String):
        self.field = field
        self.code = code
        self.message = message


struct ValidationResult(Copyable, Movable, Sized):
    var errors: List[FieldError]
    var ok: Bool

    def __init__(out self):
        self.errors = List[FieldError]()
        self.ok = True

    def __len__(self) -> Int:
        return len(self.errors)

    def merge(mut self, var other: ValidationResult):
        """Fold another result's errors into this one."""
        if not other.ok:
            self.ok = False
            for i in range(len(other.errors)):
                self.errors.append(other.errors[i].copy())
        other.ok = False  # consumed

    def to_response(self) -> Response:
        """Render a 422 response with a JSON error body."""
        var root = JsonValue.from_object()
        root.set(String("ok"), JsonValue.from_bool(False))
        var arr = JsonValue.from_array(List[JsonValue]())
        for i in range(len(self.errors)):
            ref e = self.errors[i]
            var obj = JsonValue.from_object()
            obj.set(String("field"), JsonValue.from_string(e.field))
            obj.set(String("code"), JsonValue.from_string(e.code))
            obj.set(String("message"), JsonValue.from_string(e.message))
            arr.array_push(obj^)
        root.set(String("errors"), arr^)
        var r = Response()
        r.status = 422
        r.body = _to_bytes(json_dumps(root))
        r.headers.append(Header(String("Content-Type"), String("application/json; charset=utf-8")))
        return r^


# ── Validator trait + runner ──────────────────────────────────────────────
trait Validator(Movable, Deinitable):
    """Validate a parsed JSON body. Return a ValidationResult (ok=True if the
    checked constraint holds). Implementations read only their config and the
    value — non-mut `self` so they compose through the variadic runner."""
    def validate(self, value: JsonValue) raises -> ValidationResult: ...


def validate_json[*Vs: Validator](value: JsonValue, *validators: *Vs) raises -> ValidationResult:
    """Run a comptime chain of validators over `value`, merging errors."""
    var result = ValidationResult()
    comptime for i in range(len(Vs)):
        var r = validators[i].validate(value)
        result.merge(r^)
    return result^


# ── Built-in validators ───────────────────────────────────────────────────
@fieldwise_init
struct Required(Validator, Copyable, Movable):
    """Fails if the field is absent or null."""
    var field: String

    def validate(self, value: JsonValue) raises -> ValidationResult:
        var r = ValidationResult()
        if not value.has(self.field):
            r.ok = False
            r.errors.append(FieldError(self.field, String("required"),
                String("field '") + self.field + "' is required"))
        else:
            var v = value.get(self.field)
            if v.is_null():
                r.ok = False
                r.errors.append(FieldError(self.field, String("required"),
                    String("field '") + self.field + "' must not be null"))
        return r^


@fieldwise_init
struct StringLength(Validator, Copyable, Movable):
    """Fails if the field's string value is outside [min_len, max_len].

    Skips (ok) when the field is absent — combine with `Required` to enforce
    presence. Treats a non-string value as length 0."""
    var field: String
    var min_len: Int
    var max_len: Int

    def validate(self, value: JsonValue) raises -> ValidationResult:
        var r = ValidationResult()
        if not value.has(self.field):
            return r^
        var v = value.get(self.field)
        var length: Int = 0
        if v.is_string():
            length = v.string_val.byte_length()
        var too_short = self.min_len > 0 and length < self.min_len
        var too_long = self.max_len > 0 and length > self.max_len
        if too_short:
            r.ok = False
            r.errors.append(FieldError(self.field, String("min_length"),
                String("field '") + self.field + "' must be at least " + String(self.min_len) + " characters"))
        if too_long:
            r.ok = False
            r.errors.append(FieldError(self.field, String("max_length"),
                String("field '") + self.field + "' must be at most " + String(self.max_len) + " characters"))
        return r^


@fieldwise_init
struct FieldType(Validator, Copyable, Movable):
    """Fails if the field is present but not of the expected JSON kind.

    `kind` is one of: "string" | "number" | "bool" | "object" | "array".
    Absent fields pass (combine with Required)."""
    var field: String
    var kind: String

    def validate(self, value: JsonValue) raises -> ValidationResult:
        var r = ValidationResult()
        if not value.has(self.field):
            return r^
        var v = value.get(self.field)
        var ok = False
        if self.kind == "string":
            ok = v.is_string()
        elif self.kind == "number":
            ok = v.is_number()
        elif self.kind == "bool":
            ok = v.is_bool()
        elif self.kind == "object":
            ok = v.is_object()
        elif self.kind == "array":
            ok = v.is_array()
        if not ok:
            r.ok = False
            r.errors.append(FieldError(self.field, String("type"),
                String("field '") + self.field + "' must be a " + self.kind))
        return r^


def _to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^
