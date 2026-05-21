"""Phase 2 — public API smoke test.

Exercises Request parsing, Response serialization, App.dispatch_static
on the static-mount table, and Templates render. Does NOT spin up a
socket — App.run() is verified by hand against a real curl in Phase 5.
"""

from std.collections import Dict
from std.pathlib import Path
from std.os import mkdir, makedirs

from baldr.app import App
from baldr.request import Request, parse_request
from baldr.response import Response
from baldr.templates import Templates
from baldr.template import Value
from baldr.json import JsonValue, parse as json_parse, dumps as json_dumps


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
            print(self.failures, "of", self.total, "FAILED")


# ── byte / request helpers ────────────────────────────────────────────────
def _bytes_to_str(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _raw_request(method: String, path: String, headers: String, body: String) -> List[UInt8]:
    var s = method + " " + path + " HTTP/1.1\r\n" + headers + "\r\n" + body
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


# ── Tests: Request ────────────────────────────────────────────────────────
def test_request_parse(mut r: Runner) raises:
    var raw = _raw_request(
        String("GET"),
        String("/api/users?id=42&name=adam"),
        String("Host: localhost\r\nX-Test: yes\r\n"),
        String(""),
    )
    var req = parse_request(raw)
    r.check(String("method GET"), req.method == "GET")
    r.check(String("path stripped of query"), req.path == "/api/users")
    r.check(String("query preserved"), req.query == "id=42&name=adam")
    r.check(String("Host header present"), req.headers["Host"] == "localhost")
    r.check(String("X-Test header present"), req.headers["X-Test"] == "yes")


def test_request_body_with_content_length(mut r: Runner) raises:
    var body = String("name=adam&color=blue")
    var raw = _raw_request(
        String("POST"),
        String("/api/form"),
        String("Content-Type: application/x-www-form-urlencoded\r\nContent-Length: ")
            + String(body.byte_length()) + "\r\n",
        body,
    )
    var req = parse_request(raw)
    r.check(String("POST method"), req.method == "POST")
    r.check(String("body equals form"), req.body == body)
    var form = req.form()
    r.check(String("form name"), form["name"] == "adam")
    r.check(String("form color"), form["color"] == "blue")


def test_request_json(mut r: Runner) raises:
    var body = String("{\"x\":1,\"y\":\"hello\"}")
    var raw = _raw_request(
        String("POST"),
        String("/api/echo"),
        String("Content-Length: ") + String(body.byte_length()) + "\r\n",
        body,
    )
    var req = parse_request(raw)
    var j = req.json()
    r.check(String("json parses object"), j.is_object())
    r.check(String("json x == 1"), j.get(String("x")).number_val == 1.0)


def test_request_url_decode(mut r: Runner) raises:
    var body = String("name=jane+doe&city=NY%2C")
    var raw = _raw_request(
        String("POST"),
        String("/api/form"),
        String("Content-Length: ") + String(body.byte_length()) + "\r\n",
        body,
    )
    var req = parse_request(raw)
    var form = req.form()
    r.check(String("plus → space"), form["name"] == "jane doe")
    r.check(String("%2C → comma"), form["city"] == "NY,")


# ── Tests: Response ───────────────────────────────────────────────────────
def test_response_text(mut r: Runner) raises:
    var resp = Response.text(String("hi"), 200)
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("status line 200 OK"), s.find(String("HTTP/1.1 200 OK")) == 0)
    r.check(String("text mime"), s.find(String("Content-Type: text/plain; charset=utf-8")) > 0)
    r.check(String("body present"), s.find(String("\r\nhi")) > 0)
    r.check(String("content-length 2"), s.find(String("Content-Length: 2")) > 0)


def test_response_json(mut r: Runner) raises:
    var v = json_parse(String("{\"ok\":true}"))
    var resp = Response.json(v, 201)
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("status 201"), s.find(String("HTTP/1.1 201 Created")) == 0)
    r.check(String("json mime"), s.find(String("application/json")) > 0)
    r.check(String("body has ok"), s.find(String("\"ok\":true")) > 0)


def test_response_redirect(mut r: Runner) raises:
    var resp = Response.redirect(String("/login"), 302)
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("302 status"), s.find(String("HTTP/1.1 302 Found")) == 0)
    r.check(String("Location header"), s.find(String("Location: /login")) > 0)


def test_response_with_header(mut r: Runner) raises:
    var resp = Response.text(String("hi"), 200).with_header(
        String("X-Custom"), String("yes"))
    var s = _bytes_to_str(resp.to_bytes())
    r.check(String("custom header"), s.find(String("X-Custom: yes")) > 0)


# ── Tests: App static mount ───────────────────────────────────────────────
def test_app_static_mount(mut r: Runner, tmpdir: String) raises:
    var p = Path(tmpdir + "/hello.txt")
    var content_bytes = String("hello-from-disk").as_bytes()
    var content_list = List[UInt8](capacity=len(content_bytes))
    for i in range(len(content_bytes)):
        content_list.append(content_bytes[i])
    p.write_bytes(content_list)

    var app = App()
    app.static(String("/static"), tmpdir)

    var req = Request()
    req.method = String("GET")
    req.path = String("/static/hello.txt")
    var resp = app.dispatch_static(req)
    r.check(String("static 200"), resp.status == 200)
    r.check(String("static body matches"), _bytes_to_str(resp.body) == "hello-from-disk")


def test_app_static_unmatched(mut r: Runner) raises:
    var app = App()
    app.static(String("/static"), String("/tmp"))

    var req = Request()
    req.method = String("GET")
    req.path = String("/notstatic")
    var raised = False
    try:
        _ = app.dispatch_static(req)
    except:
        raised = True
    r.check(String("unmatched static raises"), raised)


# ── Tests: Templates ──────────────────────────────────────────────────────
def test_templates_basic(mut r: Runner, tmpdir: String) raises:
    var tpl_path = Path(tmpdir + "/greet.html")
    var src = String("<h1>{{ name | upper }}</h1>")
    var src_bytes = src.as_bytes()
    var src_list = List[UInt8](capacity=len(src_bytes))
    for i in range(len(src_bytes)):
        src_list.append(src_bytes[i])
    tpl_path.write_bytes(src_list)

    var tpls = Templates(tmpdir)
    var ctx = Value.dict()
    ctx.set(String("name"), Value.string(String("adam")))
    var out = tpls.render(String("greet.html"), ctx)
    r.check(String("templates render upper"), out == "<h1>ADAM</h1>")

    var out2 = tpls.render(String("greet.html"), ctx)
    r.check(String("templates cached"), out2 == "<h1>ADAM</h1>")


def test_templates_missing(mut r: Runner, tmpdir: String) raises:
    var tpls = Templates(tmpdir)
    var ctx = Value.dict()
    var raised = False
    try:
        _ = tpls.render(String("no_such.html"), ctx)
    except:
        raised = True
    r.check(String("missing template raises"), raised)


def main() raises:
    var r = Runner()
    var tmpdir = String("/tmp/baldr_phase2_tests")
    try:
        makedirs(tmpdir, exist_ok=True)
    except:
        pass

    test_request_parse(r)
    test_request_body_with_content_length(r)
    test_request_json(r)
    test_request_url_decode(r)

    test_response_text(r)
    test_response_json(r)
    test_response_redirect(r)
    test_response_with_header(r)

    test_app_static_mount(r, tmpdir)
    test_app_static_unmatched(r)

    test_templates_basic(r, tmpdir)
    test_templates_missing(r, tmpdir)

    r.summary()
