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

The transport primitives are ready here; integration with baldr's accept loop
lands with the separate `App` rework.
