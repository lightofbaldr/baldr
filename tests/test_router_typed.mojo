"""Typed integer route parameter tests."""

from baldr.router import (
    Params, RoutePattern, Router,
    ROUTE_METHOD_NOT_ALLOWED, ROUTE_NOT_FOUND, ROUTE_OK,
    SEG_PARAM_INT,
)


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
            raise Error("typed router test failures: " + String(self.failures))


def main() raises:
    var runner = Runner()
    var typed = RoutePattern(String("/items/{id:int}"))
    runner.check("typed segment stores param name", typed.segments[1].kind == SEG_PARAM_INT and typed.segments[1].value == "id")

    var positive = typed.match(String("/items/42"))
    runner.check("typed int matches positive decimal", positive is not None)
    if positive is not None:
        runner.check("typed int captures raw value", positive.value().get_int(String("id")) == 42)

    var negative = typed.match(String("/items/-7"))
    runner.check("typed int matches negative decimal", negative is not None)
    if negative is not None:
        runner.check("negative value parses", negative.value().get_int(String("id")) == -7)

    runner.check("typed int accepts explicit plus", typed.match(String("/items/+9")) is not None)
    runner.check("typed int rejects text", typed.match(String("/items/banana")) is None)
    runner.check("typed int rejects decimal point", typed.match(String("/items/4.2")) is None)
    runner.check("typed int rejects sign without digits", typed.match(String("/items/-")) is None)
    runner.check("typed int rejects whitespace", typed.match(String("/items/%2042")) is None)
    runner.check("typed int rejects empty segment", typed.match(String("/items/")) is None)

    var fallback = Router()
    fallback.get(String("/items/{id:int}"), String("by_id"))
    fallback.get(String("/items/{slug}"), String("by_slug"))
    var by_id = fallback.resolve(String("GET"), String("/items/42"))
    runner.check("int route wins first for numbers", by_id.status == ROUTE_OK and by_id.name == "by_id")
    var by_slug = fallback.resolve(String("GET"), String("/items/banana"))
    runner.check("later untyped route catches rejected text", by_slug.status == ROUTE_OK and by_slug.name == "by_slug")

    var bad = typed.match(String("/items/42"))
    if bad is not None:
        bad.value().data[String("id")] = String("banana")
        runner.check("get_int_or defaults on non-numeric", bad.value().get_int_or(String("id"), 11) == 11)
        runner.check("get_int_or defaults on missing", bad.value().get_int_or(String("missing"), 12) == 12)

    var methods = Router()
    methods.get(String("/items/{id:int}"), String("get_id"))
    methods.post(String("/items/{slug}"), String("post_slug"))
    var typed_rejected = methods.resolve(String("DELETE"), String("/items/banana"))
    runner.check(
        "405 Allow excludes typed route rejected by segment",
        typed_rejected.status == ROUTE_METHOD_NOT_ALLOWED and typed_rejected.allowed == "POST",
    )
    var no_match = methods.resolve(String("GET"), String("/other/banana"))
    runner.check("unmatched table path remains 404", no_match.status == ROUTE_NOT_FOUND)

    runner.finish()
