"""Generate a buildable baldr application from the current checkout.

Usage: baldr_new <name> [--dir <parent>] [--routes]
"""

from std.os import makedirs
from std.pathlib import Path, cwd
from std.sys import argv


struct NewConfig(Copyable, Movable):
    var name: String
    var parent: String
    var routes: Bool

    def __init__(out self):
        self.name = String()
        self.parent = String(".")
        self.routes = False


def _usage():
    print("Usage: baldr_new <name> [--dir <parent>] [--routes]")
    print("")
    print("  name             Project and binary name (letters, digits, - and _)")
    print("  --dir <parent>   Parent directory (default: current directory)")
    print("  --routes         Generate a RouteHandler example")


def _parse_args() raises -> NewConfig:
    var config = NewConfig()
    var args = argv()
    var i = 1
    while i < len(args):
        var arg = String(args[i])
        if arg == "--":
            i += 1
        elif arg == "--dir":
            if i + 1 >= len(args):
                raise Error("baldr new: --dir requires a parent directory")
            config.parent = String(args[i + 1])
            i += 2
        elif arg == "--routes":
            config.routes = True
            i += 1
        elif arg == "-h" or arg == "--help":
            _usage()
            return config^
        elif arg.startswith("--"):
            raise Error("baldr new: unknown option: " + arg)
        elif config.name.byte_length() == 0:
            config.name = arg^
            i += 1
        else:
            raise Error("baldr new: expected one project name, got: " + arg)
    return config^


def _valid_name(name: String) -> Bool:
    var bytes = name.as_bytes()
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        var alpha = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        var digit = c >= 48 and c <= 57
        if not alpha and not digit and c != 45 and c != 95:
            return False
    return True


def _write(path: String, content: String) raises:
    Path(path).write_bytes(content.as_bytes())


def _render(template: String, name: String, baldr_src: String) -> String:
    var with_name = template.replace("__APP_NAME__", name)
    return with_name.replace("__BALDR_SRC__", baldr_src)


def _pixi_template() -> String:
    return String(
        """[workspace]
channels = ["https://conda.modular.com/max", "conda-forge"]
name = "__APP_NAME__"
platforms = ["linux-64", "linux-aarch64"]

[tasks]
build = "mkdir -p build && mojo build src/main.mojo -I '__BALDR_SRC__' -o build/__APP_NAME__"
run = "build/__APP_NAME__"
dev = "bash dev.sh"
test = "mkdir -p build && mojo build tests/test_app.mojo -I src -I '__BALDR_SRC__' -o build/test_app && build/test_app"

[dependencies]
mojo = "==1.0.0"
max = "==26.5.0"
"""
    )


def _dispatch_main_template() -> String:
    return String(
        """from baldr.app import App, DispatchHandler
from baldr.json import JsonValue
from baldr.middleware.chain import Chain, SecurityHeaders, RequestLogger
from baldr.request import Request
from baldr.response import Response
from baldr.template import Value
from baldr.templates import Templates


@fieldwise_init
struct Site(DispatchHandler, Copyable, Movable):
    var templates: Templates

    def __call__(mut self, req: Request) raises -> Response:
        if req.method == "GET" and req.path == "/":
            var context = Value.dict()
            context.set("app_name", Value.string("__APP_NAME__"))
            return Response.html(self.templates.render("index.html", context))
        if req.method == "GET" and req.path == "/health":
            var health = JsonValue.from_object()
            health.set("ok", JsonValue.from_bool(True))
            return Response.json(health^)
        return Response.text("404 not found\\n", 404)


def main() raises:
    var app = App(
        middleware=Chain((SecurityHeaders(), RequestLogger())),
    )
    app.static("/static", "public")
    app.run(Site(Templates("templates")), port=8080)
"""
    )


def _routes_main_template() -> String:
    return String(
        """from baldr.app import App, RouteHandler
from baldr.middleware.chain import Chain, SecurityHeaders, RequestLogger
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params
from baldr.template import Value
from baldr.templates import Templates


@fieldwise_init
struct Site(RouteHandler, Copyable, Movable):
    var templates: Templates

    def __call__(
        mut self,
        req: Request,
        params: Params,
        name: String,
    ) raises -> Response:
        if name == "index":
            var context = Value.dict()
            context.set("app_name", Value.string("__APP_NAME__"))
            return Response.html(self.templates.render("index.html", context))
        if name == "item":
            return Response.text("item " + params.get("id") + "\\n")
        return Response.text("404 not found\\n", 404)


def main() raises:
    var app = App(
        middleware=Chain((SecurityHeaders(), RequestLogger())),
    )
    app.static("/static", "public")
    app.get("/", "index")
    app.get("/items/{id}", "item")
    app.run(Site(Templates("templates")), port=8080)
"""
    )


def _dispatch_test_template() -> String:
    return String(
        """from baldr.app import App
from baldr.middleware.chain import Chain, SecurityHeaders, RequestLogger
from baldr.response import Response
from baldr.templates import Templates
from baldr.testing import get
from main import Site


def _body(response: Response) -> String:
    var out = String()
    for i in range(len(response.body)):
        out += chr(Int(response.body[i]))
    return out^


def main() raises:
    var failures = 0
    var app = App(middleware=Chain((SecurityHeaders(), RequestLogger())))
    var site = Site(Templates("templates"))

    var index = app.handle(site, get("/"))
    if index.status == 200 and _body(index).find("hello from __APP_NAME__") >= 0:
        print("[ok] index renders the project template")
    else:
        failures += 1
        print("[FAIL] index renders the project template")

    var health = app.handle(site, get("/health"))
    if health.status == 200:
        print("[ok] health status is 200")
    else:
        failures += 1
        print("[FAIL] health status is 200")
    if _body(health) == "{\\\"ok\\\":true}":
        print("[ok] health body is JSON")
    else:
        failures += 1
        print("[FAIL] health body is JSON")

    print("---")
    print(3 - failures, "/ 3 passed")
    if failures > 0:
        raise Error("generated app smoke-test failures: " + String(failures))
"""
    )


def _routes_test_template() -> String:
    return String(
        """from baldr.app import App
from baldr.middleware.chain import Chain, SecurityHeaders, RequestLogger
from baldr.response import Response
from baldr.templates import Templates
from baldr.testing import get
from main import Site


def _body(response: Response) -> String:
    var out = String()
    for i in range(len(response.body)):
        out += chr(Int(response.body[i]))
    return out^


def main() raises:
    var failures = 0
    var app = App(middleware=Chain((SecurityHeaders(), RequestLogger())))
    app.get("/", "index")
    app.get("/items/{id}", "item")
    var site = Site(Templates("templates"))

    var index = app.handle(site, get("/"))
    if index.status == 200 and _body(index).find("hello from __APP_NAME__") >= 0:
        print("[ok] named index route renders")
    else:
        failures += 1
        print("[FAIL] named index route renders")

    var item = app.handle(site, get("/items/7"))
    if item.status == 200 and _body(item) == "item 7\\n":
        print("[ok] item route receives its id parameter")
    else:
        failures += 1
        print("[FAIL] item route receives its id parameter")

    var missing = app.handle(site, get("/missing"))
    if missing.status == 404:
        print("[ok] unmatched route is 404")
    else:
        failures += 1
        print("[FAIL] unmatched route is 404")

    print("---")
    print(3 - failures, "/ 3 passed")
    if failures > 0:
        raise Error("generated route smoke-test failures: " + String(failures))
"""
    )


def _index_template() -> String:
    return String(
        """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ app_name }}</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <main>
    <p class="eyebrow">baldr · pure Mojo HTTP</p>
    <h1>hello from {{ app_name }}</h1>
    <p>Edit <code>templates/index.html</code>; the dev loop will rebuild and restart.</p>
  </main>
</body>
</html>
"""
    )


def _style_template() -> String:
    return String(
        """:root { color-scheme: dark; font-family: system-ui, sans-serif; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #11130f; color: #ecebdc; }
main { width: min(42rem, calc(100% - 3rem)); }
.eyebrow { color: #a9b58d; letter-spacing: .12em; text-transform: uppercase; }
h1 { font-size: clamp(2.5rem, 9vw, 6rem); line-height: .95; margin: .3em 0; }
code { color: #c8d6a8; }
"""
    )


def _dev_template() -> String:
    return String(
        """#!/usr/bin/env bash
set -u

binary="build/__APP_NAME__"
stamp="build/.dev-stamp"
server_pid=""
rebuild_count=0

stop_server() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

cleanup() { stop_server; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

rebuild() {
  rebuild_count=$((rebuild_count + 1))
  stop_server
  mkdir -p build
  touch "$stamp"
  if pixi run build; then
    "$binary" &
    server_pid=$!
    echo "[dev] rebuild $rebuild_count complete (pid $server_pid)"
  else
    echo "[dev] rebuild $rebuild_count failed"
  fi
}

rebuild
while sleep 1; do
  changed=$(find src -type f -name '*.mojo' -newer "$stamp" -print -quit)
  if [[ -z "$changed" ]]; then
    changed=$(find templates -type f -newer "$stamp" -print -quit)
  fi
  if [[ -n "$changed" ]]; then
    rebuild
  fi
done
"""
    )


def _readme_template() -> String:
    return String(
        """# __APP_NAME__

A baldr application generated from a local checkout.

```bash
pixi install
pixi run build
pixi run run
```

Open <http://127.0.0.1:8080/>. The health endpoint is
<http://127.0.0.1:8080/health> in the default scaffold.

During development, run `pixi run dev`. It polls `src/**/*.mojo` and
`templates/**` once per second, rebuilds, stops the previous server, and starts
the new binary.

Run the generated smoke test with `pixi run test`.

## baldr checkout

The generated build and test tasks include baldr from:

`__BALDR_SRC__`

This absolute path keeps the first build deterministic without a package
manager. If you move either checkout, update both `-I` paths in `pixi.toml`.
"""
    )


def generate_project(name: String, parent: String, routes: Bool = False) raises -> String:
    """Create one project and return its path. Existing targets are refused."""
    if not _valid_name(name):
        raise Error(
            "baldr new: invalid project name; use only letters, digits, '-' and '_'"
        )
    if parent.byte_length() == 0:
        raise Error("baldr new: parent directory cannot be empty")

    var checkout = cwd()
    var baldr_src_path = checkout / "src"
    var baldr_src = baldr_src_path.path
    if not (baldr_src_path / "baldr" / "app.mojo").is_file():
        raise Error(
            "baldr new: run the generator from the baldr checkout; expected "
            + baldr_src + "/baldr/app.mojo"
        )
    if baldr_src.find(String("'")) >= 0 or baldr_src.find(String("\n")) >= 0:
        raise Error("baldr new: checkout path contains a shell-unsafe quote or newline")

    var target_path = Path(parent) / name
    var target = target_path.path
    if target_path.exists():
        raise Error("baldr new: refusing to overwrite existing directory: " + target)

    makedirs(target_path / "src", exist_ok=True)
    makedirs(target_path / "templates", exist_ok=True)
    makedirs(target_path / "public", exist_ok=True)
    makedirs(target_path / "tests", exist_ok=True)

    _write(target + "/pixi.toml", _render(_pixi_template(), name, baldr_src))
    _write(
        target + "/src/main.mojo",
        _render(
            _routes_main_template() if routes else _dispatch_main_template(),
            name,
            baldr_src,
        ),
    )
    _write(
        target + "/tests/test_app.mojo",
        _render(
            _routes_test_template() if routes else _dispatch_test_template(),
            name,
            baldr_src,
        ),
    )
    _write(target + "/templates/index.html", _index_template())
    _write(target + "/public/style.css", _style_template())
    _write(target + "/dev.sh", _render(_dev_template(), name, baldr_src))
    _write(target + "/README.md", _render(_readme_template(), name, baldr_src))
    _write(target + "/.gitignore", String("build/\n.pixi/\n"))

    return target^


def main() raises:
    var config = _parse_args()
    if config.name.byte_length() == 0:
        _usage()
        return
    var target = generate_project(config.name, config.parent, config.routes)
    print("[baldr new] created " + target)
    print("[baldr new] next: cd " + target + " && pixi install && pixi run build")
