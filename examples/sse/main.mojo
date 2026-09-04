"""Server-Sent Events with a StreamHandler.

`GET /` serves a page whose EventSource subscribes to `GET /events`; the
handler streams five `tick` events one second apart through a
`ResponseStream`, then finishes. Run:
    pixi run example-sse && build/example-sse        (:8100)
    curl -N http://127.0.0.1:8100/events
"""
from std.ffi import external_call, c_uint

from baldr.app import App, StreamHandler
from baldr.request import Request
from baldr.streaming import ResponseStream


def _sleep_s(s: Int):
    _ = external_call["sleep", c_uint, c_uint](c_uint(s))


comptime PAGE = String(
    "<!doctype html><title>baldr sse</title>"
    "<h1>ticks</h1><ul id=\"out\"></ul>"
    "<script>const es=new EventSource('/events');"
    "es.addEventListener('tick',e=>{const li=document.createElement('li');"
    "li.textContent=e.data;document.getElementById('out').appendChild(li);});"
    "es.addEventListener('done',()=>es.close());</script>"
)


@fieldwise_init
struct Ticks(StreamHandler, Copyable, Movable):
    var served: Int

    def __call__(mut self, req: Request, mut out: ResponseStream) raises:
        if req.path == "/events":
            self.served += 1
            out.start(content_type=String("text/event-stream"))
            for i in range(5):
                out.send_event(String("tick ") + String(i + 1), event=String("tick"), id=String(i + 1))
                _sleep_s(1)
            out.send_event(String("bye"), event=String("done"))
            out.finish()
            return
        if req.path == "/":
            out.start(content_type=String("text/html; charset=utf-8"))
            out.write(PAGE)
            out.finish()
            return
        out.start(status=404)
        out.write(String("404 not found\n"))
        out.finish()


def main() raises:
    var app = App()
    app.run(Ticks(0), port=8100)
