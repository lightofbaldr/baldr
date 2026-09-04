# JSON

`baldr.json` is a pure-Mojo, RFC-8259 JSON parser and serializer. One type, `JsonValue`, models every JSON shape; two free functions parse and render. For a walkthrough see the [JSON tutorial](../tutorial/json.md); this is the full surface.

## `JsonValue`

A tagged union over the six JSON types. Public scalar fields let you read a value once you know its type.

### Constructors

| Constructor | Makes |
|---|---|
| `JsonValue.from_null()` | `null` |
| `JsonValue.from_bool(b: Bool)` | a boolean |
| `JsonValue.from_int(n: Int)` | a number from an `Int` |
| `JsonValue.from_number(n: Float64)` | a number from a `Float64` |
| `JsonValue.from_string(s: String)` | a string |
| `JsonValue.from_array(var xs: List[JsonValue])` | an array |
| `JsonValue.from_object()` | an empty object |

### Type predicates

`is_null()`, `is_bool()`, `is_number()`, `is_string()`, `is_array()`, `is_object()` — each returns `Bool`.

### Scalar fields

Once a predicate confirms the type, read the matching public field:

| Field | Type | Valid when |
|---|---|---|
| `bool_val` | `Bool` | `is_bool()` |
| `number_val` | `Float64` | `is_number()` |
| `string_val` | `String` | `is_string()` |

### Object access

| Method | Signature | Does |
|---|---|---|
| `set` | `set(mut self, key: String, var v: JsonValue)` | insert / replace a key |
| `get` | `get(self, key: String) -> JsonValue` | value for a key |
| `has` | `has(self, key: String) -> Bool` | key present? |
| `object_len` | `object_len(self) -> Int` | number of keys |

### Array access

| Method | Signature | Does |
|---|---|---|
| `array_push` | `array_push(mut self, var v: JsonValue)` | append |
| `array_at` | `array_at(self, i: Int) -> JsonValue` | element at index |
| `array_len` | `array_len(self) -> Int` | length |

## Free functions

| Function | Signature | Does |
|---|---|---|
| `parse` | `parse(s: String) raises -> JsonValue` | parse a JSON string (raises on malformed input) |
| `dumps` | `dumps(v: JsonValue) -> String` | serialize, compact |
| `dumps_pretty` | `dumps_pretty(v: JsonValue, indent: Int = 2) -> String` | serialize, indented |

## Round-trip example

```mojo
from baldr.json import JsonValue, parse, dumps, dumps_pretty

# parse
var v = parse("{\"name\": \"baldr\", \"tags\": [\"mojo\", \"web\"]}")
var name = v.get("name").string_val          # "baldr"
var first_tag = v.get("tags").array_at(0).string_val   # "mojo"

# build
var out = JsonValue.from_object()
out.set("ok", JsonValue.from_bool(True))
out.set("count", JsonValue.from_int(len(name)))

# render
var compact = dumps(out)                # {"ok":true,"count":5}
var pretty  = dumps_pretty(out, indent=4)
```

!!! note "Numbers are `Float64`"
    JSON has one number type, so `from_int` and `from_number` both land in `number_val` (a `Float64`). Read integer-valued fields as `Int(v.number_val)` when you need an `Int`.

See also: **[Request & Response](request-response.md)** — `Request.json()` returns a `JsonValue`, `Response.json(value)` serializes one.
