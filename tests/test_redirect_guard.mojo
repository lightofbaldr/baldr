"""Response.redirect() open-redirect / scheme guard — dangerous targets collapse
to "/", legitimate relative and http(s) targets are preserved."""

from baldr.response import Response


def _location(r: Response) -> String:
    for i in range(len(r.headers)):
        if r.headers[i].key == "Location":
            return r.headers[i].value
    return String("")


def main() raises:
    var total = 0
    var fail = 0

    total += 1
    if _location(Response.redirect(String("javascript:alert(1)"))) == String("/"):
        print("[ok] javascript: neutralized")
    else:
        fail += 1
        print("[FAIL] javascript: not neutralized")

    total += 1
    if _location(Response.redirect(String("//evil.com/x"))) == String("/"):
        print("[ok] protocol-relative //host neutralized")
    else:
        fail += 1
        print("[FAIL] protocol-relative not neutralized")

    total += 1
    if _location(Response.redirect(String("data:text/html,<script>1</script>"))) == String("/"):
        print("[ok] data: neutralized")
    else:
        fail += 1
        print("[FAIL] data: not neutralized")

    total += 1
    if _location(Response.redirect(String("/dashboard"))) == String("/dashboard"):
        print("[ok] relative path preserved")
    else:
        fail += 1
        print("[FAIL] relative path changed")

    total += 1
    if _location(Response.redirect(String("https://example.com/x"))) == String("https://example.com/x"):
        print("[ok] https target preserved")
    else:
        fail += 1
        print("[FAIL] https target changed")

    print("---")
    print(total - fail, "/", total, "passed")
    if fail > 0:
        raise Error("test failures: " + String(fail))
