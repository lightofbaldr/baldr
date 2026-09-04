"""Fresh-process supervision fixture.

This must be built as its own executable: Mojo creates runtime threads before
`main`, which is the condition the in-process fork fixtures cannot reproduce.
"""

from std.pathlib import Path
from std.sys import argv

from baldr.app import App, DispatchHandler
from baldr.lifecycle import LifecycleHooks
from baldr.request import Request
from baldr.response import Response


def _mark(path: String) raises:
    Path(path).write_bytes(String("1\n").as_bytes())


@fieldwise_init
struct HelperLifecycle(LifecycleHooks, Copyable, Movable):
    var root: String

    def on_startup(mut self) raises:
        _mark(self.root + "/started")

    def on_shutdown(mut self) raises:
        _mark(self.root + "/stopped")


@fieldwise_init
struct HelperHandler(DispatchHandler, Copyable, Movable):
    var _unused: Int

    def __init__(out self):
        self._unused = 0

    def __call__(mut self, req: Request) raises -> Response:
        return Response.text("ok\n")


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("usage: test_supervision_pool_main <port> <marker-root>")
    var port = Int(String(args[1]))
    var root = String(args[2])
    var app = App(lifecycle=HelperLifecycle(root))
    app.run(HelperHandler(), port=port, workers=2, grace_secs=2)
