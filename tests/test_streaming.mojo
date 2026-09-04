"""Byte-exact socket tests for chunked responses, SSE, and keep-alive."""

from std.ffi import c_int

from baldr.http import (
    recv_available,
    socket_close,
    socket_pair,
    wants_keep_alive,
)
from baldr.request import parse_request, Request
from baldr.response import Header
from baldr.streaming import ResponseStream


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


def _bytes(value: String) -> List[UInt8]:
    var source = value.as_bytes()
    var out = List[UInt8](capacity=len(source))
    for i in range(len(source)):
        out.append(source[i])
    return out^


def _text(value: List[UInt8]) -> String:
    var out = String()
    for i in range(len(value)):
        out += chr(Int(value[i]))
    return out^


def _equal_bytes(left: List[UInt8], right: List[UInt8]) -> Bool:
    if len(left) != len(right):
        return False
    for i in range(len(left)):
        if left[i] != right[i]:
            return False
    return True


def _repeat(char: String, count: Int) -> String:
    var out = String()
    for _ in range(count):
        out += char
    return out^


def _default_head() -> String:
    return String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Connection: keep-alive\r\n"
        "Server: baldr/0.1\r\n"
        "\r\n"
    )


def _recv_exact(fd: c_int, count: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=count)
    while len(out) < count:
        var part = recv_available(fd, count - len(out))
        if len(part) == 0:
            break
        for i in range(len(part)):
            out.append(part[i])
    return out^


def _parse_hex(value: String) raises -> Int:
    var out = 0
    var bytes = value.as_bytes()
    if len(bytes) == 0:
        raise Error("empty chunk size")
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        var digit: Int
        if c >= 48 and c <= 57:
            digit = c - 48
        elif c >= 97 and c <= 102:
            digit = c - 97 + 10
        elif c >= 65 and c <= 70:
            digit = c - 65 + 10
        else:
            raise Error("invalid chunk size")
        out = out * 16 + digit
    return out


def _decode_chunked_body(wire: String) raises -> String:
    var header_end = wire.find(String("\r\n\r\n"))
    if header_end < 0:
        raise Error("missing response header terminator")
    var pos = header_end + 4
    var out = String()
    while True:
        var tail = String(wire[byte=pos:])
        var relative_line_end = tail.find(String("\r\n"))
        if relative_line_end < 0:
            raise Error("missing chunk-size terminator")
        var chunk_size = _parse_hex(String(tail[byte=0:relative_line_end]))
        pos += relative_line_end + 2
        if chunk_size == 0:
            var bytes = wire.as_bytes()
            if pos + 1 >= len(bytes) or bytes[pos] != 13 or bytes[pos + 1] != 10:
                raise Error("malformed final chunk")
            return out^
        var bytes = wire.as_bytes()
        if pos + chunk_size + 1 >= len(bytes):
            raise Error("truncated chunk")
        for i in range(chunk_size):
            out += chr(Int(bytes[pos + i]))
        pos += chunk_size
        if bytes[pos] != 13 or bytes[pos + 1] != 10:
            raise Error("malformed chunk payload terminator")
        pos += 2


def test_start_and_headers(mut runner: Runner) raises:
    var (writer, reader) = socket_pair()
    var headers = List[Header]()
    headers.append(Header(String("Content-Length"), String("999")))
    headers.append(Header(String("X-Test"), String("yes")))
    var stream = ResponseStream(writer)
    stream.start(extra_headers=headers^)
    var head = _text(recv_available(reader, 4096))
    runner.check("start writes HTTP status", head.startswith("HTTP/1.1 200 OK\r\n"))
    runner.check("start writes chunked framing", head.find("Transfer-Encoding: chunked\r\n") >= 0)
    runner.check("start writes keep-alive", head.find("Connection: keep-alive\r\n") >= 0)
    runner.check("start omits Content-Length", head.find("Content-Length:") < 0)
    runner.check("start preserves ordinary extra headers", head.find("X-Test: yes\r\n") >= 0)
    runner.check("started state is true", stream.started())
    runner.check("finished state starts false", not stream.finished())
    socket_close(writer)
    socket_close(reader)


def test_chunk_writes(mut runner: Runner) raises:
    var (writer, reader) = socket_pair()
    var stream = ResponseStream(writer)
    stream.start()
    _ = recv_available(reader, 4096)

    stream.write(String("hello"))
    runner.check("five-byte string chunk is exact", _text(_recv_exact(reader, 10)) == "5\r\nhello\r\n")

    stream.write(String())
    stream.write(String("x"))
    runner.check("empty string is a no-op", _text(_recv_exact(reader, 6)) == "1\r\nx\r\n")

    var large = _repeat(String("z"), 300)
    stream.write(large)
    runner.check(
        "300-byte chunk uses lowercase hexadecimal size",
        _text(_recv_exact(reader, 307)) == String("12c\r\n") + _repeat(String("z"), 300) + "\r\n",
    )

    var binary = List[UInt8]()
    binary.append(UInt8(0))
    binary.append(UInt8(1))
    binary.append(UInt8(255))
    stream.write_bytes(binary)
    var expected = List[UInt8]()
    expected.append(UInt8(51)); expected.append(UInt8(13)); expected.append(UInt8(10))
    expected.append(UInt8(0)); expected.append(UInt8(1)); expected.append(UInt8(255))
    expected.append(UInt8(13)); expected.append(UInt8(10))
    runner.check("write_bytes preserves arbitrary payload bytes", _equal_bytes(_recv_exact(reader, 8), expected))
    socket_close(writer)
    socket_close(reader)


def test_finish_and_state_errors(mut runner: Runner) raises:
    var (writer, reader) = socket_pair()
    var stream = ResponseStream(writer)
    stream.start()
    _ = recv_available(reader, 4096)
    stream.finish()
    stream.finish()
    runner.check("finish is byte-exact and idempotent", _text(_recv_exact(reader, 5)) == "0\r\n\r\n")
    runner.check("second finish emits no extra bytes", len(recv_available(reader, 1)) == 0)
    runner.check("finished state is true", stream.finished())

    var caught = False
    try:
        stream.write(String("late"))
    except:
        caught = True
    runner.check("write after finish raises", caught)

    caught = False
    try:
        stream.start()
    except:
        caught = True
    runner.check("start called twice raises", caught)
    socket_close(writer)
    socket_close(reader)

    var (writer2, reader2) = socket_pair()
    var unstarted = ResponseStream(writer2)
    caught = False
    try:
        unstarted.write(String("early"))
    except:
        caught = True
    runner.check("write before start raises", caught)
    socket_close(writer2)
    socket_close(reader2)


def test_sse(mut runner: Runner) raises:
    var (writer, reader) = socket_pair()
    var stream = ResponseStream(writer)
    stream.start(content_type=String("text/event-stream; charset=utf-8"))
    var head = _text(recv_available(reader, 4096))
    runner.check("SSE start emits no-cache", head.find("Cache-Control: no-cache\r\n") >= 0)
    stream.send_event(String("a\nb"), event=String("tick"), id=String("7"))
    runner.check(
        "SSE event is one exact HTTP chunk",
        _text(_recv_exact(reader, 41)) == "23\r\nevent: tick\nid: 7\ndata: a\ndata: b\n\n\r\n",
    )
    socket_close(writer)
    socket_close(reader)

    var (writer2, reader2) = socket_pair()
    var plain = ResponseStream(writer2)
    plain.start()
    _ = recv_available(reader2, 4096)
    var caught = False
    try:
        plain.send_event(String("no"))
    except:
        caught = True
    runner.check("send_event rejects non-SSE streams", caught)
    socket_close(writer2)
    socket_close(reader2)


def test_keep_alive(mut runner: Runner) raises:
    var http11 = parse_request(_bytes(String("GET / HTTP/1.1\r\n\r\n")))
    runner.check("HTTP/1.1 defaults to keep-alive", wants_keep_alive(http11))
    runner.check("HTTP/1.1 version is parsed", http11.version == "HTTP/1.1")

    var http11_close = parse_request(_bytes(String("GET / HTTP/1.1\r\nConnection: CLOSE\r\n\r\n")))
    runner.check("HTTP/1.1 Connection close disables persistence", not wants_keep_alive(http11_close))

    var http10 = parse_request(_bytes(String("GET / HTTP/1.0\r\n\r\n")))
    runner.check("HTTP/1.0 defaults to close", not wants_keep_alive(http10))
    runner.check("HTTP/1.0 version is parsed", http10.version == "HTTP/1.0")

    var http10_keep = parse_request(_bytes(String("GET / HTTP/1.0\r\nConnection: KeEp-AlIvE\r\n\r\n")))
    runner.check("HTTP/1.0 keep-alive value is case-insensitive", wants_keep_alive(http10_keep))

    var token_list = parse_request(_bytes(String("GET / HTTP/1.1\r\nConnection: upgrade, Close\r\n\r\n")))
    runner.check("Connection options are parsed as comma-separated tokens", not wants_keep_alive(token_list))

    var unknown = Request()
    unknown.version = String("HTTP/2")
    runner.check("unknown protocol versions default closed", not wants_keep_alive(unknown))


def test_full_round_trip(mut runner: Runner) raises:
    var (writer, reader) = socket_pair()
    var stream = ResponseStream(writer)
    stream.start()
    stream.write(String("one"))
    stream.write(String("two"))
    stream.write(String("three"))
    stream.finish()

    var expected_wire = _default_head() \
        + "3\r\none\r\n" \
        + "3\r\ntwo\r\n" \
        + "5\r\nthree\r\n" \
        + "0\r\n\r\n"
    var wire = _text(_recv_exact(reader, expected_wire.byte_length()))
    runner.check("full round trip consumes the expected wire length", wire.byte_length() == expected_wire.byte_length())
    runner.check("full round trip reassembles three payload chunks", _decode_chunked_body(wire) == "onetwothree")
    socket_close(writer)
    socket_close(reader)


def main() raises:
    var runner = Runner()
    test_start_and_headers(runner)
    test_chunk_writes(runner)
    test_finish_and_state_errors(runner)
    test_sse(runner)
    test_keep_alive(runner)
    test_full_round_trip(runner)
    runner.summary()
    if runner.failures > 0:
        raise Error("test failures: " + String(runner.failures))
