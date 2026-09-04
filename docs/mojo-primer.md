# Mojo in 5 Minutes

FastAPI's docs can assume you know Python. baldr can't quite assume you know Mojo yet — it's a young language. So here are the **six things** that will make every baldr example read naturally. If you write Python, you already understand the ideas; only the spelling is new.

You don't have to memorize this. Skim it once, build the [first app](tutorial/first-steps.md), and come back when a symbol looks foreign. Every tutorial page also flags its Mojo-isms inline, so you're never stuck.

---

## 1. Structs, not classes

Mojo's unit of structure is the **struct** — a value type, like a C struct or a Python `@dataclass`, but compiled.

```mojo
struct Counter:
    var n: Int          # `var` = a mutable field
```

There's no inheritance. Instead you conform to **traits** (interfaces), by listing them in parentheses:

```mojo
struct HelloApp(DispatchHandler, Copyable, Movable):
    ...
```

That reads: *"`HelloApp` is a struct that satisfies `DispatchHandler`, and is copyable and movable."* This is the whole reason a baldr handler is a struct — it conforms to `DispatchHandler`, and the compiler checks it has the right `__call__`. (Python analog: duck-typing, but verified at compile time.)

---

## 2. `String` and string literals

Mojo distinguishes a **string literal** (`"hi"`, a compile-time constant) from the owned, heap-backed **`String`** type. baldr's APIs take `String` — but Mojo **converts a literal to a `String` for you automatically**, so you just write the literal:

```mojo
Response.text("Hello\n")             # ✅ the literal becomes a String
app.get("/notes/{id}", "note_show")  # ✅ both literals convert
value.set("id", Value.string(id))    # ✅ no wrappers
```

You'll still see `String("...")` in some older code and corners of baldr's own source — that form works too, it's simply no longer necessary. When you see it, read it as a plain string.

!!! note "If you came here from an older tutorial"
    Early baldr required `String("...")` around every literal — a limitation of the older Mojo nightly it was written against, now lifted. Bare literals are the current idiom; the wraps are optional, not required.

---

## 3. Ownership: `mut`, `var`, `out`, `^`

Mojo has no garbage collector. Instead, every value has **one owner**, and function arguments declare how they borrow. You'll see four spellings in baldr, and each says one thing:

| Spelling | Means | Python analog |
|---|---|---|
| `req: Request` (default) | **borrow** it, read-only | pass a reference, don't mutate |
| `mut self` | **borrow** it, may mutate | a method that changes `self` |
| `var body: List[UInt8]` | **take ownership** of it | the callee now owns it |
| `out self` | the value being **constructed** | `__init__`'s `self` |

And `^` (the transfer operator) hands ownership over explicitly: `some_client.request(req^)` says "take my `req`, I'm done with it."

Why this shows up in baldr: a handler is `def __call__(mut self, ...)` because it may update its own fields (a cache, a counter) while serving a request. That mutation-between-requests is the core idea — see [The Handler](guide/handler.md).

---

## 4. `def`, `fn`, and `raises`

Mojo has two function keywords. `def` is the Python-flavored one (looser, may raise); `fn` is stricter. **baldr is written entirely in `def`** — so you can too, and it'll feel like Python.

If a function can throw, it must say `raises`:

```mojo
def __call__(mut self, req: Request) raises -> Response:
    ...

def main() raises:      # calling anything that raises makes you raise too
    ...
```

Think of `raises` as a compiler-checked version of "this can throw." If you call something that raises, you either handle it or add `raises` to your own signature. (Python analog: exceptions, but the signatures are honest about them.)

---

## 5. Decorators are built in — no imports

You'll meet `@fieldwise_init` in example #1. It's a **built-in Mojo decorator** — part of the language, nothing to import. It writes the constructor for you, one argument per field, in declaration order:

```mojo
@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    var greeting: String
    # you get HelloApp("hi") for free — no __init__ to write
```

Likewise `Copyable` and `Movable` in the parent list are built-in traits that synthesize copy/move behavior, so baldr can store your handler and hand it around. Together they're the standard boilerplate for a plain data-carrying struct.

---

## 6. Square brackets are compile-time parameters

The one that looks scary and isn't. In Mojo, `[...]` holds **compile-time parameters** and `(...)` holds runtime arguments. When you see:

```mojo
def run[H: DispatchHandler](mut self, var handler: H, port: Int): ...
```

read it as: *"`H` is some type that conforms to `DispatchHandler`, chosen at compile time; `handler` and `port` are the runtime values."* Because your handler's type is baked in at compile time, there's **no per-request vtable lookup** — the dispatch is monomorphized, which is a big part of why baldr is fast. You almost never write the `[H]` yourself; the compiler infers it from what you pass:

```mojo
var app = App()
app.run(HelloApp(), port=8080)     # H = HelloApp, inferred
```

(Python analog: generics, but resolved and specialized at build time instead of erased at runtime.)

---

## That's the whole toolkit

Structs+traits, `String`, ownership, `def/raises`, built-in decorators, `[comptime]` params. Every baldr example is built from those six ideas. When one shows up on a tutorial page, you'll get a one-line reminder pointing back here.

Ready? **[Get Started →](get-started.md)** installs the toolchain, or jump straight to **[First Steps →](tutorial/first-steps.md)**.
