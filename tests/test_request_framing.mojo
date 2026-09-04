"""Request framing hardening — reject smuggling-enabling ambiguity at the
canonical parse layer (duplicate Content-Length, any Transfer-Encoding)."""

from baldr.request import parse_request


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def main() raises:
    var total = 0
    var fail = 0

    # 1. A normal single-Content-Length request still parses.
    total += 1
    var ok: Bool
    try:
        var req = parse_request(_bytes(String("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")))
        ok = (req.body == String("hello"))
    except:
        ok = False
    if ok:
        print("[ok] single Content-Length parses")
    else:
        fail += 1
        print("[FAIL] single Content-Length parses")

    # 2. Duplicate Content-Length -> rejected (first-vs-last desync).
    total += 1
    var caught = False
    try:
        _ = parse_request(_bytes(String("POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello")))
    except:
        caught = True
    if caught:
        print("[ok] duplicate Content-Length rejected")
    else:
        fail += 1
        print("[FAIL] duplicate Content-Length rejected")

    # 3. Any Transfer-Encoding -> rejected (chunked desync behind a proxy).
    total += 1
    caught = False
    try:
        _ = parse_request(_bytes(String("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")))
    except:
        caught = True
    if caught:
        print("[ok] Transfer-Encoding rejected")
    else:
        fail += 1
        print("[FAIL] Transfer-Encoding rejected")

    # 4. Excessive header count -> rejected (parse-side DoS guard).
    total += 1
    var many = String("GET / HTTP/1.1\r\n")
    for _ in range(200):
        many += "X-H: 1\r\n"
    many += "\r\n"
    caught = False
    try:
        _ = parse_request(_bytes(many))
    except:
        caught = True
    if caught:
        print("[ok] excessive header count rejected")
    else:
        fail += 1
        print("[FAIL] excessive header count rejected")

    print("---")
    print(total - fail, "/", total, "passed")
    if fail > 0:
        raise Error("test failures: " + String(fail))
