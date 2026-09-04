# Streaming responses

`ResponseStream` writes a response incrementally instead of building a complete
`Response` body in memory. It uses HTTP/1.1 chunked transfer encoding, so each
piece is framed with its byte length and sent immediately while the connection
stays open.

```mojo
from std.ffi import c_int
from baldr.streaming import ResponseStream


def write_progress(fd: c_int) raises:
    var stream = ResponseStream(fd)
    stream.start(content_type="text/plain; charset=utf-8")
    stream.write("starting\n")
    stream.write("working\n")
    stream.finish()
```

`start()` emits the status line, `Transfer-Encoding: chunked`, and
`Connection: keep-alive`; it never emits `Content-Length`. `write()` sends one
UTF-8 string as one chunk, while `write_bytes()` preserves an arbitrary byte
payload. An empty chunk is ignored because the zero-length chunk is reserved for
`finish()`. `finish()` writes that terminator once and is safe to call again.
Writing before `start()` or after `finish()` raises.

Every call writes directly through `write_all`. There is no userspace buffer to
flush: `write_all` loops when `send(2)` accepts only part of a buffer. The stream
does not close its socket descriptor; the server's accept loop owns that
lifetime.

## Server-Sent Events

Start with `text/event-stream`, then call `send_event()`:

```mojo
var events = ResponseStream(fd)
events.start(content_type="text/event-stream")
events.send_event("queued", event="status", id="1")
events.send_event("line one\nline two", event="status", id="2")
events.finish()
```

The stream adds `Cache-Control: no-cache`. Each call becomes one HTTP chunk;
multiline data is framed as one `data:` line per input line, followed by the SSE
blank line. `event:` and `id:` are omitted when empty. `send_event()` rejects a
stream started with any other content type.

`Response.sse(events)` remains available for finite feeds that fit in a normal
response body. Use `ResponseStream` when events must reach the client while the
handler is still producing them.

## Keep-alive policy

`wants_keep_alive(request)` implements the HTTP version rules used by the
transport:

- HTTP/1.1 persists unless `Connection` contains the `close` token.
- HTTP/1.0 closes unless `Connection` contains `keep-alive`.
- Unknown protocol versions close by default.

Header names and connection tokens are compared case-insensitively. The request
parser retains the request-line version in `request.version`.

## In an App: `StreamHandler`

Conform a struct to `StreamHandler` and hand it to `app.run(...)` like any
other handler. Per request the App gives you the parsed `Request` and a
`ResponseStream` already bound to the client socket:

```mojo
from baldr.app import App, StreamHandler
from baldr.request import Request
from baldr.streaming import ResponseStream

@fieldwise_init
struct Ticks(StreamHandler, Copyable, Movable):
    var served: Int

    def __call__(mut self, req: Request, mut out: ResponseStream) raises:
        if req.path == "/events":
            self.served += 1
            out.start(content_type="text/event-stream")
            for i in range(5):
                out.send_event("tick " + String(i + 1), event="tick", id=String(i + 1))
            out.finish()
            return
        out.start(status=404)
        out.write("404 not found\n")
        out.finish()

def main() raises:
    var app = App()
    app.run(Ticks(0), port=8100)
```

What the App does around your handler:

- static and asset mounts still answer first, as ordinary buffered responses;
- the middleware `before` chain runs and may short-circuit with a buffered
  response (a `429` from `RateLimitMW`, say); `after` hooks do **not** run
  for a streamed response — its headers are already on the wire;
- if you return without `finish()`, the App finishes the stream for you;
- if your handler raises before `start()`, the App renders the error handler's
  `500` as a normal response; if it raises after, the connection is closed;
- `app.serve_connection(fd, handler)` is the same loop on one socket, which is
  how `tests/test_app_keepalive.mojo` tests a stream handler through a socket
  pair; `workers=N` preforks stream handlers like any other.

`examples/sse/main.mojo` is the runnable version: `pixi run example-sse &&
build/example-sse`, then `curl -N http://127.0.0.1:8100/events`.

## Keep-alive in the accept loop

Every `run` keeps a connection open across requests when `wants_keep_alive`
says so: HTTP/1.1 by default, HTTP/1.0 only with `Connection: keep-alive`.
The response carries the `Connection:` header the loop decided on (a
`Connection` header set on the `Response` is dropped so the wire never
contradicts the loop). The first request on a connection gets the 15 s read
budget; each following request gets `KEEPALIVE_IDLE_SECS` (2 s) before the
worker moves on, so an idle browser connection cannot park a worker for
long. Pipelined requests are handled: bytes after the first complete request
are kept and served next. A streamed response keeps the connection open too,
provided the handler finished its stream cleanly.
