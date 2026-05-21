"""baldr — chat example.

Single-pane chat with auto-escaping HTML via `baldr.Templates`. State
lives in the dispatcher struct (`ChatApp`) between requests — the
trait-based dispatcher design lets handlers own their persistent
state without needing a global runtime singleton.

Build:
    pixi run example-chat
Run:
    build/example-chat
Probe (in another shell):
    curl -s http://127.0.0.1:8092/
    curl -s -X POST -d 'who=adam&body=hello' http://127.0.0.1:8092/api/send
    curl -s http://127.0.0.1:8092/
"""

from std.time import perf_counter_ns

from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.template import Value
from baldr.templates import Templates
from baldr.middleware.security_headers import apply_security_headers
from baldr.middleware.logger import log_request


struct ChatMsg(Copyable, Movable):
    var id: Int
    var who: String
    var body: String

    def __init__(out self, id: Int, who: String, body: String):
        self.id = id
        self.who = who
        self.body = body


@fieldwise_init
struct ChatApp(DispatchHandler, Movable):
    var messages: List[ChatMsg]
    var next_id: Int
    var templates: Templates

    def render_page(mut self) raises -> String:
        var ctx = Value.dict()
        ctx.set(String("count"), Value.int_(len(self.messages)))
        if len(self.messages) == 1:
            ctx.set(String("count_suffix"), Value.string(String("")))
        else:
            ctx.set(String("count_suffix"), Value.string(String("s")))
        ctx.set(String("default_who"), Value.string(String("anonymous")))

        var msg_list = Value.list_of()
        for i in range(len(self.messages)):
            ref m = self.messages[i]
            var v = Value.dict()
            v.set(String("id"), Value.int_(m.id))
            v.set(String("who"), Value.string(m.who))
            v.set(String("body"), Value.string(m.body))
            msg_list.push(v^)
        ctx.set(String("messages"), msg_list^)

        return self.templates.render(String("chat.html"), ctx)

    def __call__(mut self, req: Request) raises -> Response:
        var t0 = perf_counter_ns()
        var resp: Response

        if req.method == "GET" and req.path == "/":
            var html = self.render_page()
            resp = Response.html(html)
        elif req.method == "POST" and req.path == "/api/send":
            try:
                var form = req.form()
                var who = form["who"] if form.__contains__(String("who")) else String("anon")
                var body = form["body"] if form.__contains__(String("body")) else String()
                if body.byte_length() == 0:
                    resp = Response.text(String("400 missing body\n"), 400)
                else:
                    self.messages.append(ChatMsg(self.next_id, who, body))
                    self.next_id += 1
                    resp = Response.redirect(String("/"))
            except:
                resp = Response.text(String("400 bad form\n"), 400)
        else:
            resp = Response.text(String("404\n"), 404)

        resp = apply_security_headers(resp^)
        log_request(req, resp, t0)
        return resp^


def main() raises:
    var app = App()
    var templates = Templates(String("examples/chat/templates"))
    var chat = ChatApp(
        messages=List[ChatMsg](),
        next_id=1,
        templates=templates^,
    )
    app.run(chat^, port=8092)
