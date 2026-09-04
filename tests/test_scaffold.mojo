"""Filesystem tests for the `baldr new` project generator."""

from std.pathlib import Path, cwd

from baldr.http import process_getpid
from baldr_new import generate_project


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

    def summary(self):
        print("---")
        if self.failures == 0:
            print(self.total, "/", self.total, "passed")
        else:
            print(self.failures, "of", self.total, "FAILED")


def main() raises:
    var runner = Runner()
    var suffix = String(Int(process_getpid()))
    var name = String("scaffold_") + suffix
    var project = generate_project(name, String("build"))

    var expected: List[String] = [
        "pixi.toml",
        "src/main.mojo",
        "templates/index.html",
        "public/style.css",
        "tests/test_app.mojo",
        "README.md",
        ".gitignore",
        "dev.sh",
    ]
    for relative in expected:
        runner.check(
            "generated " + relative,
            Path(project + "/" + relative).is_file(),
        )

    var pixi = Path(project + "/pixi.toml").read_text()
    var baldr_src = (cwd() / "src").path
    runner.check("pixi pins Mojo 1.0.0", pixi.find("mojo = \"==1.0.0\"") >= 0)
    runner.check("pixi pins MAX 26.5.0", pixi.find("max = \"==26.5.0\"") >= 0)
    runner.check("pixi uses the Modular channel", pixi.find("https://conda.modular.com/max") >= 0)
    runner.check("pixi includes linux-64", pixi.find("linux-64") >= 0)
    runner.check("pixi includes linux-aarch64", pixi.find("linux-aarch64") >= 0)
    runner.check("pixi embeds the absolute baldr src path", pixi.find(baldr_src) >= 0)
    runner.check("pixi exposes the dev loop", pixi.find("dev = \"bash dev.sh\"") >= 0)

    var main_source = Path(project + "/src/main.mojo").read_text()
    runner.check("default scaffold is a DispatchHandler", main_source.find("DispatchHandler") >= 0)
    runner.check("generated source uses a named app.run", main_source.find("app.run(") >= 0)
    runner.check("generated source never calls App().run", main_source.find("App().run") < 0)
    runner.check("generated source uses no deprecated runner", main_source.find(".run_") < 0)
    runner.check("default scaffold registers static files", main_source.find("app.static(\"/static\", \"public\")") >= 0)
    runner.check("default scaffold has the health route", main_source.find("req.path == \"/health\"") >= 0)

    var dev = Path(project + "/dev.sh").read_text()
    runner.check("dev loop polls Mojo sources", dev.find("find src -type f -name '*.mojo' -newer") >= 0)
    runner.check("dev loop polls templates", dev.find("find templates -type f -newer") >= 0)
    runner.check("dev loop kills the recorded server pid", dev.find("kill \"$server_pid\"") >= 0)

    var duplicate_raised = False
    var duplicate_clear = False
    try:
        _ = generate_project(name, String("build"))
    except error:
        duplicate_raised = True
        duplicate_clear = String(error).find("refusing to overwrite existing directory") >= 0
    runner.check("generating twice raises", duplicate_raised)
    runner.check("overwrite error names the refusal", duplicate_clear)

    var invalid_raised = False
    try:
        _ = generate_project(String("../escape"), String("build"))
    except:
        invalid_raised = True
    runner.check("unsafe project names are rejected", invalid_raised)

    var routes_name = String("scaffold_routes_") + suffix
    var routes_project = generate_project(routes_name, String("build"), routes=True)
    var routes_source = Path(routes_project + "/src/main.mojo").read_text()
    runner.check("routes scaffold is a RouteHandler", routes_source.find("RouteHandler") >= 0)
    runner.check("routes scaffold registers index", routes_source.find("app.get(\"/\", \"index\")") >= 0)
    runner.check("routes scaffold registers item params", routes_source.find("app.get(\"/items/{id}\", \"item\")") >= 0)
    runner.check("routes scaffold uses app.run", routes_source.find("app.run(") >= 0)

    runner.summary()
    if runner.failures > 0:
        raise Error("test failures: " + String(runner.failures))
