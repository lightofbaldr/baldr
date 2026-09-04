# Request & Response

The two types every handler touches. `Request` is what baldr hands you; `Response` is what you return. Both are plain structs — read fields directly, build replies with the static constructors.

## `Request`

The parsed HTTP request. Fields are public — read them directly:

| Field | Type | Notes |
|---|---|---|
| `method` | `String` | `"GET"`, `"POST"`, … |
| `path` | `String` | the URL path, e.g. `/notes/7` |
| `query` | `String` | the raw query string (after `?`) |
| `body` | `String` | the raw request body |
| `headers` | `Dict[String, String]` | header name → value |

### Methods

| Method | Signature | Returns |
|---|---|---|
| `header` | `header(self, name) -> String` | one header value (empty if absent) |
| `form` | `form(self) raises -> Dict[String, String]` | parsed `application/x-www-form-urlencoded` body |
| `json` | `json(self) raises -> JsonValue` | parse the current JSON body — see [JSON](json.md) |
| `cookies` | `cookies(self) -> Dict[String, String]` | all request cookies |
| `cookie` | `cookie(self, name, default=String()) -> String` | one cookie value |
| `validate` | `validate(self, *validators) raises -> ValidationResult` | parse the JSON body once, validate it, and expose it as `result.value` |

```mojo
def __call__(mut self, req: Request) raises -> Response:
    var ua = req.header("User-Agent")
    var theme = req.cookie("theme", "light")
    if req.method == "POST":
        var form = req.form()
        ...
    return Response.text("ok\n")
```

Validation keeps its existing non-raising field-error contract (`result.ok`, `result.to_response()`); malformed JSON still raises. On success—or a parsed body that fails field validation—`result.value` is the parsed `JsonValue`, so handlers do not need a second `json()` call. A direct `json()` call parses the request's current body and works on the immutable `Request` binding passed to handlers.

## `Response`

Build a response with a static constructor, then optionally chain headers and cookies.

### Constructors

| Constructor | Signature | Content-Type |
|---|---|---|
| `text` | `text(body, status=200) -> Response` | `text/plain` |
| `html` | `html(body, status=200) -> Response` | `text/html` |
| `json` | `json(value: JsonValue, status=200) -> Response` | `application/json` |
| `redirect` | `redirect(location, status=302) -> Response` | — (sets `Location`) |
| `sse` | `sse(events: List[String]) -> Response` | `text/event-stream` |
| `file` | `file(path) raises -> Response` | inferred from extension |

### Instance methods

| Method | Signature | Use |
|---|---|---|
| `with_header` | `with_header(self, key, value) -> Response` | chainable; returns a new Response |
| `add_header` | `add_header(mut self, key, value)` | in place |
| `with_cookie` | `with_cookie(self, var sc: SetCookie) -> Response` | chainable |
| `add_cookie` | `add_cookie(mut self, var sc: SetCookie)` | in place |
| `to_bytes` | `to_bytes(self) -> List[UInt8]` | serialize to the wire (baldr calls this for you) |

```mojo
return Response.html("<h1>hi</h1>") \
    .with_header("X-Frame-Options", "DENY") \
    .with_cookie(SetCookie("seen", "1").with_max_age(3600))
```

!!! note "`with_*` vs `add_*`"
    `with_header` / `with_cookie` return a new `Response` so you can chain them onto a constructor in one expression. `add_header` / `add_cookie` mutate in place (`mut self`) when you already hold a `var response`. Same effect; pick by what reads cleaner.

### `Header`

A single response header — `Header(key, value)`. You rarely construct one directly; the builders above manage headers for you.

## Cookies

Two types, in `baldr.cookies`. `Cookie` is a name/value pair you read off a request. `SetCookie` is what you send back, with a fluent builder for attributes:

| Builder method | Sets |
|---|---|
| `with_domain(domain)` | `Domain=` |
| `with_path(path)` | `Path=` |
| `with_expires(expires)` | `Expires=` |
| `with_max_age(seconds)` | `Max-Age=` |
| `with_http_only()` | `HttpOnly` |
| `with_secure()` | `Secure` |
| `same_site_strict()` / `same_site_lax()` / `same_site_none()` | `SameSite=` |
| `to_header()` | render the full `Set-Cookie` value |

```mojo
from baldr.cookies import SetCookie

var sc = SetCookie("session", token) \
    .with_http_only() \
    .with_secure() \
    .same_site_lax() \
    .with_max_age(86400)
return Response.text("logged in\n").with_cookie(sc^)
```

!!! note "Bare literals, no `String(...)` needed"
    Mojo converts a string literal to `String` automatically, so header names, cookie names, and values all take bare literals — `Header("X-Frame-Options", "DENY")`, `SetCookie("session", token)`. (Previously a rough edge that forced `String(...)` everywhere — fixed in this version.) See [Mojo in 5 Minutes](../mojo-primer.md#2-string-and-string-literals).

See also: **[App](app.md)** for how a Response gets served, and **[Router & Params](router.md)** for what fills `req.path`.
