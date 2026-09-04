"""Phase 2.7 — config + error handler tests."""

from std.collections import Dict

from baldr.request import Request
from baldr.response import Response
from baldr.config import ServerConfig
from baldr.errors import ErrorHandler, JsonErrorHandler, HtmlErrorHandler


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

    # ── ServerConfig.from_env reads env vars with defaults ────────────
    # Set a couple env vars to verify they're picked up.
    from std.os import setenv
    _ = setenv(String("BALDR_TEST_HOST"), String("1.2.3.4"))
    _ = setenv(String("BALDR_TEST_PORT"), String("9999"))
    _ = setenv(String("BALDR_TEST_DEBUG"), String("true"))

    # ServerConfig is fieldwise; build one manually to check defaults logic
    # via the from_env path by temporarily using the BALDR_TEST_* names.
    from baldr.env import env_str, env_int, env_bool
    var host = env_str(String("BALDR_TEST_HOST"), String("0.0.0.0"))
    var port = env_int(String("BALDR_TEST_PORT"), 8080)
    var debug = env_bool(String("BALDR_TEST_DEBUG"), False)
    r.check("config: host from env", host == "1.2.3.4")
    r.check("config: port from env", port == 9999)
    r.check("config: debug=true from env", debug)
    r.check("config: default port when unset", env_int(String("NOT_SET_XYZ"), 8080) == 8080)

    # ServerConfig.from_env uses HOST/PORT/DEBUG etc. (defaults if unset).
    # Don't clobber the real env; just verify the struct shape + a default.
    var cfg = ServerConfig(
        host=env_str(String("BALDR_TEST_HOST"), String("0.0.0.0")),
        port=env_int(String("BALDR_TEST_PORT"), 8080),
        debug=env_bool(String("BALDR_TEST_DEBUG"), False),
        workers=4,
        max_body_bytes=10 * 1024 * 1024,
        static_dir=String("./static"),
        template_dir=String("./templates"),
    )
    r.check("config: struct host field", cfg.host == "1.2.3.4")
    r.check("config: struct port field", cfg.port == 9999)
    r.check("config: struct debug field", cfg.debug)
    r.check("config: struct workers field", cfg.workers == 4)
    r.check("config: max_body_bytes default 10MiB", cfg.max_body_bytes == 10485760)

    # ── JsonErrorHandler ──────────────────────────────────────────────
    var jeh = JsonErrorHandler()
    var req = Request(String("GET"), String("/x"), String(), String(), Dict[String, String]())
    var jresp = jeh.render_error(404, String("widget not found"), req)
    r.check("json eh status 404", jresp.status == 404)
    var jbody = String()
    for i in range(len(jresp.body)):
        jbody += chr(Int(jresp.body[i]))
    r.check("json eh body has error label", jbody.find(String("\"error\":\"not_found\"")) >= 0)
    r.check("json eh body has message", jbody.find(String("widget not found")) >= 0)
    r.check("json eh body has status 404", jbody.find(String("\"status\":404")) >= 0)
    var jctype = String()
    for i in range(len(jresp.headers)):
        if jresp.headers[i].key == "Content-Type":
            jctype = jresp.headers[i].value
    r.check("json eh content-type", jctype == "application/json; charset=utf-8")

    # ── HtmlErrorHandler ──────────────────────────────────────────────
    var heh = HtmlErrorHandler()
    var hresp = heh.render_error(500, String("kaboom <script>"), req)
    r.check("html eh status 500", hresp.status == 500)
    var hbody = String()
    for i in range(len(hresp.body)):
        hbody += chr(Int(hresp.body[i]))
    r.check("html eh has status code", hbody.find(String("500")) >= 0)
    r.check("html eh has internal_error label", hbody.find(String("internal_error")) >= 0)
    r.check("html eh escapes message", hbody.find(String("<script>")) < 0 and hbody.find(String("&lt;script&gt;")) >= 0)
    var hctype = String()
    for i in range(len(hresp.headers)):
        if hresp.headers[i].key == "Content-Type":
            hctype = hresp.headers[i].value
    r.check("html eh content-type", hctype == "text/html; charset=utf-8")

    r.summary()
