# Config & Error Handling

Three things every real service needs: configuration from the environment, a consistent shape for error responses, and input validation. baldr gives you a typed struct for the first, a pluggable trait for the second, and composable validators for the third.

## Configuration from the environment

`ServerConfig.from_env()` reads twelve-factor-style config once, at startup. It loads a `.env` file if present (real environment variables win), then fills a typed struct:

```mojo
from baldr.config import ServerConfig

def main() raises:
    var cfg = ServerConfig.from_env()
    App().run(MyApp(), port=cfg.port)
```

Each field has a default, so an empty environment still boots:

| Field | Env var | Default |
|---|---|---|
| `host` | `HOST` | `0.0.0.0` |
| `port` | `PORT` | `8080` |
| `debug` | `DEBUG` | `False` |
| `workers` | `WORKERS` | `4` |
| `max_body_bytes` | `MAX_BODY_BYTES` | `10485760` (10 MiB) |
| `static_dir` | `STATIC_DIR` | `./static` |
| `template_dir` | `TEMPLATE_DIR` | `./templates` |

!!! note "Typed, not stringly"
    `cfg.port` is an `Int` and `cfg.debug` is a `Bool` — parsed and checked at startup, not re-parsed on every request. `from_env()` is `raises` because a malformed value (e.g. `PORT=banana`) should fail loud at boot, not silently at request time.

## Error handling

By default baldr returns a plain-text status line for errors. To control that shape — JSON for an API, HTML for a browser app — you supply an **error handler**: a struct conforming to the `ErrorHandler` trait.

```mojo
from baldr.errors import ErrorHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct MyErrors(ErrorHandler, Copyable, Movable):
    def render_error(self, status: Int, message: String, req: Request) raises -> Response:
        var body = "{\"error\":\"" + message + "\",\"status\":" + String(status) + "}"
        return Response.text(body, status).with_header("Content-Type", "application/json")
```

baldr ships two ready-made handlers so you usually don't write your own:

| Handler | Renders errors as |
|---|---|
| `JsonErrorHandler` | `{"error": "...", "status": N}` — for APIs |
| `HtmlErrorHandler` | a styled HTML page — for browser apps |

You wire an error handler in through the run methods that accept one — `run_routes_middleware_eh` or `run_full` (see [The Handler Trait](handler.md) for the full table):

```mojo
from baldr.errors import JsonErrorHandler

app.run_routes_middleware_eh(MyRoutes(), RequestLogger(), JsonErrorHandler(), port=8080)
```

Now any status baldr raises (a 404 from the router, a 500 from a handler that threw) flows through `render_error` and comes back in your chosen shape.

## Validation

For request bodies, baldr has composable **validators**. Each conforms to the `Validator` trait; you run a set of them against a `JsonValue` with `Request.validate(...)`:

```mojo
from baldr.validation import Required, StringLength, FieldType

def __call__(mut self, req: Request) raises -> Response:
    var result = req.validate(
        Required("title"),
        StringLength("title", 1, 120),
    )
    if len(result) > 0:
        return result.to_response()          # 422 with the field errors
    ...
```

The built-in validators:

| Validator | Checks |
|---|---|
| `Required(field)` | the field is present and non-null |
| `StringLength(field, min, max)` | a string field's length is in range |
| `FieldType(field, type)` | the field is the expected JSON type |

A `ValidationResult` is `Sized` — `len(result) == 0` means valid. `result.to_response()` renders a `422 Unprocessable Entity` with a machine-readable list of `FieldError`s (`field`, `code`, `message`). You can also `merge` two results to run validators in stages.

!!! warning "Rough edge — validators are per-field, not per-struct"
    You list validators one field at a time; there's no `@validate` derive that reads a struct's shape. For a handful of fields it's clear; for large payloads it's repetitive. A schema-derive is on the punch-list. Until then, keep a `validate_note()` helper next to each model.

Next: **[The GPU Queue →](queue.md)** — baldr's in-process job/KV store, optionally backed by device memory.
