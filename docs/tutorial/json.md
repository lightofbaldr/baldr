# JSON In & Out

Most APIs speak JSON. baldr ships an RFC-8259 parser and serializer in pure Mojo — no `pip install`, no C extension — behind one type: `JsonValue`. This page reads JSON off a request, builds a JSON reply, and wires up a tiny echo API.

## Reading JSON from a request

`Request.json()` parses the request body and hands you a `JsonValue`:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct EchoApp(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        var body = req.json()                       # JsonValue
        var name = body.get("name")         # -> JsonValue for that key
        return Response.text("hello " + name.string_val + "\n")
```

A `JsonValue` is a tagged union. You ask what it is, then read the matching field:

| You have | Check | Read the scalar |
|---|---|---|
| a string | `v.is_string()` | `v.string_val` → `String` |
| a number | `v.is_number()` | `v.number_val` → `Float64` |
| a bool | `v.is_bool()` | `v.bool_val` → `Bool` |
| an object | `v.is_object()` | `v.get(key)`, `v.has(key)` |
| an array | `v.is_array()` | `v.array_at(i)`, `v.array_len()` |

!!! note "`req.json()` can raise"
    A malformed body throws, so the method is `raises` — and your handler already is too (see [Mojo in 5 Minutes](../mojo-primer.md#4-def-fn-and-raises)). If the client can't be trusted, check `body.is_object()` before reaching for a key.

## Building a JSON response

You assemble a `JsonValue` with the `from_*` constructors, then mutate objects and arrays in place:

```mojo
var out = JsonValue.from_object()
out.set("ok", JsonValue.from_bool(True))
out.set("count", JsonValue.from_int(3))
out.set("name", JsonValue.from_string("baldr"))

var tags = JsonValue.from_array(List[JsonValue]())
tags.array_push(JsonValue.from_string("mojo"))
tags.array_push(JsonValue.from_string("web"))
out.set("tags", tags^)

return Response.json(out)          # Content-Type: application/json
```

`Response.json(value, status=200)` serializes and sets the header for you. The constructors you'll use:

| Constructor | Makes |
|---|---|
| `JsonValue.from_null()` | `null` |
| `JsonValue.from_bool(b)` | `true` / `false` |
| `JsonValue.from_int(n)` / `from_number(f)` | a number |
| `JsonValue.from_string(s)` | a string |
| `JsonValue.from_array(var xs)` | an array (then `array_push`) |
| `JsonValue.from_object()` | `{}` (then `set`) |

!!! note "Why `tags^`?"
    The `^` transfers ownership of `tags` into the parent object — after `set(..., tags^)` the parent owns it and you're done with the local. That's Mojo's move operator; the [primer](../mojo-primer.md#3-ownership-mut-var-out) has the one-paragraph version.

## Parsing and serializing directly

Sometimes you have a string, not a request. The top-level functions round-trip:

```mojo
from baldr.json import parse, dumps, dumps_pretty

var v = parse("{\"a\": 1, \"b\": [true, null]}")   # raises on bad input
var compact = dumps(v)                                       # {"a":1,"b":[true,null]}
var pretty  = dumps_pretty(v, indent=2)                      # 2-space indented
```

## The whole echo API

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response
from baldr.json import JsonValue

@fieldwise_init
struct Echo(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        if req.method != "POST":
            return Response.text("POST me some JSON\n", 405)
        var body = req.json()
        var reply = JsonValue.from_object()
        reply.set("you_sent", body^)
        reply.set("ok", JsonValue.from_bool(True))
        return Response.json(reply)

def main() raises:
    var app = App()
    app.run(Echo(), port=8080)
```

```console
$ curl -s localhost:8080 -X POST -d '{"msg":"hi"}'
{"you_sent":{"msg":"hi"},"ok":true}
```

!!! warning "Rough edge — no struct binding"
    There's no serde-style mapping between a Mojo struct and JSON: you hand-build every object with `set(...)` and read every field with `.string_val` / `.number_val`. It's explicit and fast, but verbose for large payloads — a `@json` derive is on the developer-experience punch-list. For now, keep JSON assembly in small helpers.

Next: **[Static Files & Assets →](static.md)** serves CSS, JS, and images — with content-hashed URLs for free caching.
