"""Baldr — SQLite notes example.

`GET /` lists notes from a file-backed SQLite database. `POST /add`
inserts one note with a bound parameter and redirects to the list.

Build:
    pixi run example-db
Run:
    build/example-db
Probe (in another shell):
    curl -s http://127.0.0.1:8098/
    curl -s -X POST -d 'body=hello+from+sqlite' http://127.0.0.1:8098/add
"""

from std.os import makedirs

from baldr.app import App, DispatchHandler
from baldr.db import Db
from baldr.request import Request
from baldr.response import Response


@fieldwise_init
struct NotesApp(DispatchHandler, Movable):
    var db: Db

    def render_index(mut self) raises -> String:
        var rows = self.db.query("SELECT id, body FROM notes ORDER BY id DESC")
        var html = String(
            "<!doctype html><html lang='en'><meta charset='utf-8'><meta"
            " name='viewport' content='width=device-width,"
            " initial-scale=1'><title>baldr.db"
            " notes</title><body><main><h1>Notes</h1><form method='post'"
            " action='/add'><label>New note <input name='body'"
            " required></label><button type='submit'>Add</button></form><ol>"
        )
        for i in range(len(rows)):
            html += (
                "<li><small>#"
                + _html_escape(rows[i].get("id"))
                + "</small> "
                + _html_escape(rows[i].get("body"))
                + "</li>"
            )
        html += "</ol></main></body></html>"
        return html^

    def __call__(mut self, req: Request) raises -> Response:
        if req.method == "GET" and req.path == "/":
            return Response.html(self.render_index())

        if req.method == "POST" and req.path == "/add":
            var form = req.form()
            var body = form["body"] if form.__contains__(
                String("body")
            ) else String()
            if body.byte_length() == 0:
                return Response.text("400 missing note\n", 400)
            var params = List[String]()
            params.append(body)
            self.db.exec("INSERT INTO notes (body) VALUES (?)", params)
            return Response.redirect("/")

        return Response.text("404\n", 404)


def _html_escape(text: String) -> String:
    var out = String()
    for codepoint in text.codepoint_slices():
        if codepoint == "&":
            out += "&amp;"
        elif codepoint == "<":
            out += "&lt;"
        elif codepoint == ">":
            out += "&gt;"
        elif codepoint == '"':
            out += "&quot;"
        elif codepoint == "'":
            out += "&#39;"
        else:
            out += String(codepoint)
    return out^


def main() raises:
    try:
        makedirs("build", exist_ok=True)
    except:
        pass
    var db = Db.open("build/baldr_notes.sqlite")
    db.exec(
        "CREATE TABLE IF NOT EXISTS notes ("
        "id INTEGER PRIMARY KEY, body TEXT NOT NULL)"
    )
    var app = App()
    var notes = NotesApp(db^)
    app.run(notes^, port=8098)
