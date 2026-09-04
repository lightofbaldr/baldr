# Why Mojo

You already have Flask, FastAPI, Django, Starlette. They work. So why would a Python developer learn a young language to write a web app?

Here's the honest answer: because baldr changes what a web app *is*. Not the code you write — that still reads like Python — but what comes out the other end. A FastAPI app is Python source that an interpreter runs, request after request, forever. A baldr app is Python-shaped Mojo source that the compiler turns into **one native binary**. The interpreter is gone. What ships is a single file that answers HTTP.

That one difference cascades into everything below. Let's walk through why it's worth it — and then, just as plainly, where baldr will bite you today.

---

## No interpreter on the request path

In FastAPI, every request runs through CPython. Your handler is bytecode; the event loop is bytecode; the JSON encoder is (mostly) bytecode. That's a lot of interpretation between the socket and your reply.

In baldr, there is none. Your handler compiles down to machine code. When a request lands, the accept loop calls one monomorphized function and writes bytes back:

```mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct HelloApp(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        return Response.text("Hello, baldr\n")

def main() raises:
    App().run(HelloApp(), port=8080)
```

That `__call__` is not being interpreted. It's compiled, inlined where the compiler can, and called directly. The whole path — parse the request, dispatch, render the response to bytes, write the socket — is your one binary running native code.

!!! note "`mut self` and `raises` — those are Mojo, not baldr"
    If the `mut self` or the `raises` keyword look unfamiliar, they're the language, not the framework. (Note that bare string literals like `"Hello, baldr\n"` just work — Mojo converts them to `String` automatically, no `String(...)` wrapping needed.) The [five-minute Mojo primer](mojo-primer.md) explains the rest in Python terms.

---

## One static binary you can ship *from scratch*

A FastAPI deploy is a supply chain: a base image, a Python runtime, `pip install` of your dependency tree, and everything those depend on. The result is hundreds of megabytes and a standing invitation for a CVE in a transitive package you've never heard of.

A baldr deploy is one file.

```console
$ pixi run build && ls -la build/app
-rwxr-xr-x  1 you you  4.1M  build/app

$ ./build/app
[baldr] listening on 0.0.0.0 port 8080
```

Because that binary has no runtime dependency, you can put it in a `FROM scratch` container with nothing else — no Python, no libc-dance, no interpreter to patch:

```console
FROM scratch
COPY build/app /app
COPY static /static
ENTRYPOINT ["/app"]
```

The attack surface is the code you wrote plus the code you linked, and nothing else. Copy the binary to any matching-arch box and it runs. That's the whole deploy story.

---

## Traits and monomorphization, not decorators over an interpreter

This is the deep one, and it's where baldr's design earns its keep.

FastAPI wires your app together at runtime. `@app.get("/")` registers a function in a dict; on each request the framework looks the route up, resolves dependencies, and calls your function through Python's dynamic dispatch. It's flexible and it's *interpreted*, every time.

baldr does the wiring at **compile time**. Your handler is a struct that conforms to the `DispatchHandler` trait, and `App.run` takes that type as a compile-time parameter:

```mojo
def run[H: DispatchHandler](
    self,
    var handler: H,
    host: String = "0.0.0.0",
    port: Int = 8080,
) raises:
    ...
```

Read the real signature from `app.mojo`: `H` in the square brackets is a compile-time type parameter, constrained to conform to `DispatchHandler`. When you call `App().run(HelloApp(), port=8080)`, the compiler picks `H = HelloApp` and stamps out a version of the accept loop specialized to *your* handler. There is **no per-request vtable lookup**, no function-pointer indirection — the call to your `__call__` is direct and inlinable.

!!! note "`[H: DispatchHandler]` is a compile-time parameter"
    Mojo puts compile-time parameters in `[...]` and runtime arguments in `(...)`. You almost never write the `[H]` yourself — the compiler infers it from what you pass. Section 6 of the [primer](mojo-primer.md) has the two-minute version.

The same trick powers middleware. A middleware pipeline in baldr is a *variadic compile-time* stack, unrolled at build time — not a list walked by the interpreter on every request:

```mojo
comptime for i in range(len(Ms)):
    var pre = mws[i].before(req)
    if pre.status != MW_PASS:
        resp = pre^
        blocked = True
        break
```

That `comptime for` (straight from `Chain.before`) runs *at compile time*. The loop is unrolled; each middleware's `before` call is monomorphized in place. Your five-stage pipeline becomes five direct, inlined calls, not five dictionary lookups.

And because a handler is a struct, it **owns its state between requests**. A rate limiter's counters, a template cache, a queue handle — they're fields on your struct, initialized once, mutated in place via `mut self`. No `global`, no dependency-injection container, no per-request re-instantiation. The state model is just… a struct.

---

## One source, vectorized to your CPU

Mojo's SIMD is portable by construction. You write vector-width-agnostic code once, and the compiler lowers it to **AVX2 on an x86 server and Neon on an ARM laptop** from the same source. No intrinsics, no `#ifdef`, no maintaining two copies. The hot paths inside baldr — header scanning, byte copying, the response renderer — get this for free, and so does any numeric code you write in a handler.

For a Python developer this is the part with no analog. NumPy gets you vectorized *libraries*; Mojo gets you vectorized *your code*, on whatever chip you deploy to, from one file.

---

## GPU through MAX, not hand-written CUDA

baldr targets both `linux-aarch64` and `linux-64`, and when a handler needs a GPU, the path is **MAX** — Modular's compiler and inference stack — not raw CUDA you write and maintain by hand. The bundle ships a GPU-resident work queue as an example of this: model work runs on the accelerator, orchestrated from the same Mojo you wrote the web layer in.

The point isn't that baldr is a GPU framework — it's a web framework. The point is that when your endpoint needs to run a model, you don't leave the language to do it. Which brings us to the real thesis.

---

## One language, from the route to the kernel

This is what nothing else on the Python side can offer.

Today, a realistic ML-serving app is a language sandwich: Python for the web layer, C++/CUDA for the kernels, and a fragile FFI seam stitching them together. You debug across an interpreter boundary. You profile across a runtime boundary. You ship two toolchains.

In baldr, `Response.text(...)`, the SIMD header-scan, and a GPU matmul are all **the same language**. The web handler, the vectorized inner loop, and the accelerator kernel share one type system, one compiler, one debugger, one build. There's no seam because there's nothing to seam. You can start at `def __call__(mut self, req)` and follow the call all the way down to the hardware without changing languages once.

That's the bet. Not "Mojo is faster" — though it is — but "Mojo collapses the stack."

---

## Now the honest part

baldr is **pre-alpha**. Mojo itself is a 1.0-beta language. If you adopt this today, you are early, and early has a cost. Here's the real bill, no sugar.

!!! warning "The toolchain is pinned to an exact nightly"
    baldr pins the specific Mojo/MAX nightly it was validated against (`mojo = "==1.0.0b3.dev2026070123"`). The 1.0 betas move fast and occasionally break source between nightlies, so a loose `>=` can pull a build baldr wasn't tested on. Copy the pin verbatim. See [Get Started](get-started.md) for the exact `pixi.toml`.

!!! warning "No package manager yet"
    There is no `pip install baldr`. You clone the source and depend on it with a relative include flag: `mojo build src/main.mojo -I ../mojo-bundle/src`. Mojo's package story is still maturing; a published package and a `baldr new` scaffold are on the near-term roadmap, but today the honest primitive is a git checkout and an `-I`.

!!! note "Streaming is finite, for now"
    `Response.sse(...)` builds a real Server-Sent Events reply, but baldr sends the whole event list at once under `Connection: close` rather than holding the socket open. That's fine for a finite feed; true long-lived streaming needs keep-alive + chunked writes in the transport layer, which is planned but not here yet.

None of these are secrets we're hiding — you'll notice we flag them on nearly every page. That honesty *is* the house voice, and it's also how the punch-list gets shorter. (Two items that used to live on this list — wrapping every string literal in `String(...)`, and routing handlers re-deriving the match by hand — are fixed: literals convert to `String` automatically, and `RouteHandler.__call__` now receives the matched route's `name` directly, so you dispatch with `if name == "note_show":` instead of re-resolving the path yourself.)

---

## So why adopt it now?

Because the rough edges are ergonomic, and the foundation is not.

Every item on that list is a wrapper, a scaffold, or a pin — surface polish that a maturing toolchain and a few releases will file down. What's *underneath* — no interpreter on the request path, one static binary, compile-time dispatch, portable SIMD, one language to the kernel — is the architecture, and the architecture is already real. 428 tests green, a prefork worker pool that actually parallelizes, bit-equivalence oracles on the wire format. The hard part works; the easy part is being finished.

Getting in early means you learn the model while it's small enough to hold in your head, you shape the framework while its API is still soft, and you own the category before it's crowded. If "the FastAPI of Mojo" is going to be a thing — and the interpreter-free, one-binary, one-language story says it should be — the people who were here at pre-alpha will be the ones who wrote the guides everyone else reads.

You write Python-shaped code. You get a native binary. That trade is available today.

**[Get Started →](get-started.md)** installs the toolchain, or jump straight to **[First Steps →](tutorial/first-steps.md)**.
