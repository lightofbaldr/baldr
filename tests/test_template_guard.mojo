"""Template loader path-traversal guard — {% include %} / load() cannot escape
the template directory via '..', absolute paths, backslashes, or NUL."""

from baldr.templates import Templates


def main() raises:
    var t = Templates(String("templates/"))
    var total = 0
    var fail = 0

    # '..' traversal -> blocked by the guard (distinct from a plain not-found).
    total += 1
    var blocked = False
    try:
        _ = t.load(String("../../etc/passwd"))
    except e:
        blocked = String(e).find(String("unsafe")) >= 0
    if blocked:
        print("[ok] '..' traversal blocked by guard")
    else:
        fail += 1
        print("[FAIL] '..' traversal not blocked")

    # absolute path -> blocked.
    total += 1
    blocked = False
    try:
        _ = t.load(String("/etc/passwd"))
    except e:
        blocked = String(e).find(String("unsafe")) >= 0
    if blocked:
        print("[ok] absolute path blocked by guard")
    else:
        fail += 1
        print("[FAIL] absolute path not blocked")

    # embedded NUL -> blocked.
    total += 1
    blocked = False
    try:
        _ = t.load(String("a") + chr(0) + String("b"))
    except e:
        blocked = String(e).find(String("unsafe")) >= 0
    if blocked:
        print("[ok] NUL blocked by guard")
    else:
        fail += 1
        print("[FAIL] NUL not blocked")

    # A safe name passes the guard (it then fails as not-found, NOT as 'unsafe').
    total += 1
    var guard_ok = True
    try:
        _ = t.load(String("page.html"))
    except e:
        guard_ok = String(e).find(String("unsafe")) < 0
    if guard_ok:
        print("[ok] safe name passes the guard")
    else:
        fail += 1
        print("[FAIL] safe name wrongly blocked")

    print("---")
    print(total - fail, "/", total, "passed")
    if fail > 0:
        raise Error("test failures: " + String(fail))
