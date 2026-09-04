"""Phase 2.1 — routing example.

Demonstrates App.run with a RouteHandler: dispatch by the matched
route NAME, path params, 405, 404.
Run: pixi run example-route && build/example-route   (listens on :8095)
"""
from baldr.app import App, RouteHandler
from baldr.request import Request
from baldr.response import Response
from baldr.router import Params


@fieldwise_init
struct NotesApp(RouteHandler, Copyable, Movable):
    var title: String

    def __call__(mut self, req: Request, params: Params, name: String) raises -> Response:
        # Dispatch by the matched route NAME — the Router already resolved it,
        # so the route table registered in main() stays the single source of
        # truth (no re-checking req.path here).
        if name == "index":
            return Response.html("<h1>" + self.title + " notes</h1>")
        if name == "note_show":
            return Response.text("note #" + params.get("id", "?") + "\n")
        if name == "note_create":
            return Response.text("created\n", 201)
        if name == "note_delete":
            return Response.text("deleted\n", 204)
        return Response.text("404 not found\n", 404)


def main() raises:
    var app = App()
    app.static("/static", "./static")
    app.get("/", "index")
    app.get("/notes/{id}", "note_show")
    app.post("/notes", "note_create")
    app.delete("/notes/{id}", "note_delete")

    app.run(NotesApp("baldr"), port=8095)
