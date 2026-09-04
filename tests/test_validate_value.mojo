"""Immutable Request JSON access and retained validation-value tests."""

from std.collections import Dict

from baldr.json import JsonValue, dumps as json_dumps
from baldr.request import Request
from baldr.validation import Required, ValidationResult


struct Runner(Copyable, Movable):
    var total: Int
    var failures: Int

    def __init__(out self):
        self.total = 0
        self.failures = 0

    def check(mut self, label: String, condition: Bool):
        self.total += 1
        if condition:
            print("[ok]", label)
        else:
            self.failures += 1
            print("[FAIL]", label)

    def finish(self) raises:
        print("---")
        print(self.total - self.failures, "/", self.total, "passed")
        if self.failures > 0:
            raise Error("validate value test failures: " + String(self.failures))


def _request(body: String) -> Request:
    return Request(String("POST"), String("/"), String(), body, Dict[String, String]())


def _json_from_immutable_request(req: Request) raises -> JsonValue:
    """Match the immutable Request binding supplied to real handlers."""
    return req.json()


def _validate_immutable_request(req: Request) raises -> ValidationResult:
    """Match the immutable Request binding supplied to real handlers."""
    return req.validate(Required(String("name")))


def main() raises:
    var runner = Runner()

    var validated = _request(String("{\"name\":\"Ada\",\"roles\":[\"admin\"]}"))
    var result = _validate_immutable_request(validated)
    runner.check("validate succeeds through immutable Request", result.ok)
    runner.check(
        "validate result retains the complete parsed value",
        json_dumps(result.value) == "{\"name\":\"Ada\",\"roles\":[\"admin\"]}",
    )

    var current = _request(String("{\"name\":\"Ada\"}"))
    var first = _json_from_immutable_request(current)
    runner.check("json parses through immutable Request", first.get(String("name")).string_val == "Ada")
    current.body = String("{\"name\":\"Grace\"}")
    var second = _json_from_immutable_request(current)
    runner.check("json parses the current body without a cache", second.get(String("name")).string_val == "Grace")

    var invalid_fields = _request(String("{\"other\":1}"))
    var invalid_result = _validate_immutable_request(invalid_fields)
    runner.check("field failures keep the non-raising result contract", not invalid_result.ok)
    runner.check("failed result still exposes parsed value", invalid_result.value.has(String("other")))

    var bad_json = _request(String("{broken"))
    var json_raised = False
    try:
        _ = _json_from_immutable_request(bad_json)
    except:
        json_raised = True
    runner.check("malformed JSON raises from json", json_raised)

    var bad_validate = _request(String("{broken"))
    var validate_raised = False
    try:
        _ = _validate_immutable_request(bad_validate)
    except:
        validate_raised = True
    runner.check("malformed JSON raises from validate", validate_raised)

    runner.finish()
