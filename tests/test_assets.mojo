"""Phase 2.6 — asset pipeline tests (hash, bundle/minify, manifest, build)."""

import std.os
from std.time import perf_counter_ns
from std.pathlib import Path
from std.collections import List

from baldr.assets import (
    content_hash, bundle_js, bundle_css, build_assets,
    content_type_for_ext, manifest_to_context,
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


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _str(var b: List[UInt8]) -> String:
    var out = String()
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def main() raises:
    var r = Runner()

    # ── content_hash: deterministic, 16 hex chars, varies on input ──────
    var h1 = content_hash(_bytes(String("hello")))
    var h1b = content_hash(_bytes(String("hello")))
    var h2 = content_hash(_bytes(String("world")))
    r.check("hash is 16 hex chars", h1.byte_length() == 16)
    r.check("hash is deterministic", h1 == h1b)
    r.check("hash differs on input", h1 != h2)
    var allhex = True
    for i in range(h1.byte_length()):
        var c = h1[byte=i]
        var ok = (c >= "0" and c <= "9") or (c >= "a" and c <= "f")
        if not ok:
            allhex = False
    r.check("hash is lowercase hex", allhex)

    # ── content_type_for_ext ───────────────────────────────────────────
    r.check("ct .js", content_type_for_ext(String(".js")).find(String("javascript")) >= 0)
    r.check("ct .css", content_type_for_ext(String(".css")).find(String("text/css")) >= 0)
    r.check("ct .png", content_type_for_ext(String(".png")) == String("image/png"))
    r.check("ct unknown -> octet-stream", content_type_for_ext(String(".xyz")) == String("application/octet-stream"))

    # ── bundle_js: strips // and /* */ comments, collapses blank lines ─
    var js = List[String]()
    js.append(String("// header comment\nvar x = 1; // inline\n/* block\n  multi */\n\n\nvar y = 2;\n"))
    var bundled = bundle_js(js^)
    var js_out = _str(bundled^)
    r.check("js: // line comment stripped", js_out.find(String("// header")) < 0)
    r.check("js: block comment stripped", js_out.find(String("block")) < 0)
    r.check("js: code preserved", js_out.find(String("var x = 1;")) >= 0 and js_out.find(String("var y = 2;")) >= 0)
    r.check("js: blank-line runs collapsed", js_out.find(String("\n\n\n")) < 0)

    # ── bundle_css: strips comments, collapses ws ─────────────────────
    var css = List[String]()
    css.append(String("/* main */\nbody {\n  color : red  ;\n  margin : 0  ;\n}\n"))
    var cbundled = bundle_css(css^)
    var css_out = _str(cbundled^)
    r.check("css: comment stripped", css_out.find(String("main */")) < 0)
    r.check("css: rules preserved", css_out.find(String("color")) >= 0 and css_out.find(String("margin")) >= 0)
    r.check("css: no ' : ' ws inside kept tight", css_out.find(String("color:red")) >= 0 or css_out.find(String("color : red")) < 0)

    # ── build_assets end-to-end on a temp dir ──────────────────────────
    var root = String("/tmp/baldr_assets_test_") + String(perf_counter_ns())
    _ = std.os.mkdir(root, 0o755)
    var outdir = root + String("_out")
    _ = std.os.mkdir(outdir, 0o755)
    Path(root + String("/app.js")).write_text(String("var a = 1; // c\n"))
    Path(root + String("/style.css")).write_text(String("/* c */ body { color: red; }\n"))
    Path(root + String("/logo.png")).write_text(String("PNGBYTES"))

    var manifest = build_assets(root, outdir, String("/static"), True)

    r.check("manifest has 3 records", len(manifest.records) == 3)
    r.check("manifest url_for app.js", manifest.url_for(String("app.js")).startswith(String("/static/app.")) and manifest.url_for(String("app.js")).endswith(String(".js")))
    r.check("manifest url_for style.css", manifest.url_for(String("style.css")).find(String(".css")) >= 0)
    r.check("manifest has app.js", manifest.has(String("app.js")))
    r.check("manifest find_by_url works", manifest.find_by_url(manifest.url_for(String("app.js"))) is not None)
    r.check("manifest find_by_url unknown -> None", manifest.find_by_url(String("/static/nope.js")) is None)
    r.check("manifest content_type app.js -> js", manifest.content_type_for(String("app.js")).find(String("javascript")) >= 0)

    # hashed output file written
    var app_url = manifest.url_for(String("app.js"))
    var out_filename = String(app_url[byte=String("/static").byte_length():])
    if out_filename.byte_length() > 0 and out_filename[byte=0:1] == "/":
        # dev2026080106 aliasing rule: materialise before self-assign (same as
        # app.mojo / serve.mojo path strips).
        var of_stripped = String(out_filename[byte=1:])
        out_filename = of_stripped^
    r.check("hashed output file exists", Path(outdir + String("/") + out_filename).exists())

    # minify took effect: output has no comment
    var built_bytes = Path(outdir + String("/") + out_filename).read_bytes()
    var built_str = _str(built_bytes^)
    r.check("built js has no // comment", built_str.find(String("// c")) < 0)

    # ── manifest_to_context (template integration) ────────────────────
    var ctx = manifest_to_context(manifest)
    r.check("context maps app.js -> url", ctx[String("app.js")] == manifest.url_for(String("app.js")))
    r.check("context maps style.css -> url", ctx[String("style.css")] == manifest.url_for(String("style.css")))

    # ── no-minify passthrough ──────────────────────────────────────────
    var manifest2 = build_assets(root, outdir, String("/static"), False)
    # passthrough preserves the comment
    var app2_url = manifest2.url_for(String("app.js"))
    var fn2 = String(app2_url[byte=String("/static").byte_length():])
    if fn2.byte_length() > 0 and fn2[byte=0:1] == "/":
        var fn2_stripped = String(fn2[byte=1:])
        fn2 = fn2_stripped^
    var built2 = _str(Path(outdir + String("/") + fn2).read_bytes())
    r.check("no-minify preserves comment", built2.find(String("// c")) >= 0)

    r.summary()
