"""Streaming HTTP/1.1 responses over an already-connected socket.

`ResponseStream` writes chunked response bytes immediately.  It does not close
the file descriptor; the accept loop remains responsible for socket lifetime.
"""

from std.ffi import c_int

from .http import write_all
from .response import Header


struct ResponseStream(Movable):
    """A single chunked response bound to a connected socket descriptor.

    The stream is intentionally not `Copyable`: duplicating its state could
    emit two header blocks or two terminators onto one connection.
    """

    var _fd: c_int
    var _started: Bool
    var _finished: Bool
    var _sse: Bool

    def __init__(out self, fd: c_int):
        self._fd = fd
        self._started = False
        self._finished = False
        self._sse = False

    def start(
        mut self,
        status: Int = 200,
        content_type: String = "text/plain; charset=utf-8",
        var extra_headers: List[Header] = List[Header](),
    ) raises:
        """Write the status line and chunked keep-alive headers immediately.

        Transport-owned headers in `extra_headers` are ignored so callers
        cannot reintroduce `Content-Length` or contradict chunked framing.
        Header controls are stripped at this wire-format choke point.
        """
        if self._started:
            raise Error("ResponseStream.start() called more than once")

        var safe_content_type = _strip_header_controls(content_type)
        var media_type = safe_content_type.lower()
        var semicolon = media_type.find(String(";"))
        if semicolon >= 0:
            var media_prefix = String(media_type[byte=0:semicolon])
            media_type = media_prefix^
        self._sse = String(media_type.strip()) == "text/event-stream"

        var head = String("HTTP/1.1 ") + _status_text(status) + "\r\n"
        head += "Content-Type: " + safe_content_type + "\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: keep-alive\r\n"
        head += "Server: baldr/0.1\r\n"
        if self._sse:
            head += "Cache-Control: no-cache\r\n"

        for i in range(len(extra_headers)):
            ref header = extra_headers[i]
            var lower_key = header.key.lower()
            if lower_key == "content-length" or lower_key == "transfer-encoding" \
                or lower_key == "connection" or lower_key == "content-type":
                continue
            if self._sse and lower_key == "cache-control":
                continue
            head += _strip_header_controls(header.key) + ": " \
                + _strip_header_controls(header.value) + "\r\n"
        head += "\r\n"

        var wire = _string_to_bytes(head^)
        write_all(self._fd, wire)
        self._started = True

    def write(mut self, chunk: String) raises:
        """Write one UTF-8 string as one HTTP chunk."""
        self.write_bytes(_string_to_bytes(chunk))

    def write_bytes(mut self, chunk: List[UInt8]) raises:
        """Write one byte buffer as one HTTP chunk.

        `write_all` loops on partial `send(2)` results, so this method returns
        only after the complete framing and payload have been handed to the
        socket (or the existing transport helper encounters a send error).
        """
        self._require_writable()
        if len(chunk) == 0:
            return

        var prefix = _hex_size(len(chunk)) + "\r\n"
        var prefix_bytes = prefix.as_bytes()
        var wire = List[UInt8](capacity=len(prefix_bytes) + len(chunk) + 2)
        for i in range(len(prefix_bytes)):
            wire.append(prefix_bytes[i])
        for i in range(len(chunk)):
            wire.append(chunk[i])
        wire.append(UInt8(13))
        wire.append(UInt8(10))
        write_all(self._fd, wire)

    def send_event(
        mut self,
        data: String,
        event: String = "",
        id: String = "",
    ) raises:
        """Frame and send one Server-Sent Event as one HTTP chunk."""
        self._require_writable()
        if not self._sse:
            raise Error("ResponseStream.send_event() requires text/event-stream")

        var payload = String()
        if event.byte_length() > 0:
            payload += "event: " + _strip_sse_field(event) + "\n"
        if id.byte_length() > 0:
            payload += "id: " + _strip_sse_field(id) + "\n"
        var lines = data.split(String("\n"))
        for line in lines:
            payload += "data: " + String(line) + "\n"
        payload += "\n"
        self.write(payload^)

    def finish(mut self) raises:
        """Write the terminating zero chunk. Repeated calls are no-ops."""
        if not self._started:
            raise Error("ResponseStream.finish() called before start()")
        if self._finished:
            return
        var terminator = _string_to_bytes(String("0\r\n\r\n"))
        write_all(self._fd, terminator)
        self._finished = True

    def started(self) -> Bool:
        return self._started

    def finished(self) -> Bool:
        return self._finished

    def _require_writable(self) raises:
        if not self._started:
            raise Error("ResponseStream write called before start()")
        if self._finished:
            raise Error("ResponseStream write called after finish()")


def _hex_size(value: Int) -> String:
    if value == 0:
        return String("0")
    var digits = String("0123456789abcdef")
    var reversed_digits = String()
    var remaining = value
    while remaining > 0:
        reversed_digits += String(digits[byte=remaining & 0xF])
        remaining >>= 4
    var out = String()
    # The temporary contains only ASCII hexadecimal digits, so reverse by byte.
    var i = reversed_digits.byte_length()
    while i > 0:
        i -= 1
        out += String(reversed_digits[byte=i])
    return out^


def _string_to_bytes(value: String) -> List[UInt8]:
    var source = value.as_bytes()
    var out = List[UInt8](capacity=len(source))
    for i in range(len(source)):
        out.append(source[i])
    return out^


def _strip_sse_field(value: String) -> String:
    """Keep `event` and `id` on one SSE line."""
    var out = String()
    for cp in value.codepoint_slices():
        var bytes = cp.as_bytes()
        if len(bytes) == 1 and (bytes[0] == 0x0D or bytes[0] == 0x0A):
            continue
        out += String(cp)
    return out^


def _strip_header_controls(value: String) -> String:
    var out = String()
    for cp in value.codepoint_slices():
        var bytes = cp.as_bytes()
        if len(bytes) == 1 and (
            bytes[0] == 0x0D or bytes[0] == 0x0A or bytes[0] == 0x00
        ):
            continue
        out += String(cp)
    return out^


def _status_text(code: Int) -> String:
    if code == 200: return String("200 OK")
    if code == 201: return String("201 Created")
    if code == 204: return String("204 No Content")
    if code == 301: return String("301 Moved Permanently")
    if code == 302: return String("302 Found")
    if code == 303: return String("303 See Other")
    if code == 304: return String("304 Not Modified")
    if code == 307: return String("307 Temporary Redirect")
    if code == 308: return String("308 Permanent Redirect")
    if code == 400: return String("400 Bad Request")
    if code == 401: return String("401 Unauthorized")
    if code == 403: return String("403 Forbidden")
    if code == 404: return String("404 Not Found")
    if code == 405: return String("405 Method Not Allowed")
    if code == 409: return String("409 Conflict")
    if code == 413: return String("413 Payload Too Large")
    if code == 422: return String("422 Unprocessable Entity")
    if code == 429: return String("429 Too Many Requests")
    if code == 500: return String("500 Internal Server Error")
    if code == 502: return String("502 Bad Gateway")
    if code == 503: return String("503 Service Unavailable")
    if code == 504: return String("504 Gateway Timeout")
    return String(code) + " Status"
