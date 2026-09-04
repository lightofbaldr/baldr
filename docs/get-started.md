# Get Started

baldr is a Mojo library. You need the Mojo toolchain (via [pixi](https://pixi.sh)), the baldr source on disk, and one `-I` include flag. That's it — the output is a single native binary.

!!! tip "New to Mojo? Read [Mojo in 5 Minutes](mojo-primer.md) first."
    Coming from Python, six small language differences explain everything you'll see in the examples. Five-minute read, and the rest of the docs click into place.

## Scaffold a project

From a baldr checkout, generate a complete starter project:

```console
$ pixi run new -- myapp
$ cd myapp
$ pixi install
$ pixi run build
$ pixi run run
```

The scaffold includes a handler, HTML template, static CSS, smoke test, and pinned Mojo/MAX environment. During development, use the polling rebuild loop instead:

```console
$ pixi run dev
```

It rebuilds when a file under `src/` or `templates/` changes, stops the previous child process, and starts the new binary. Pass `--routes` to generate a named `RouteHandler` example, or `--dir <parent>` to choose the parent directory.

The generated `pixi.toml` records the absolute path to this checkout's `src/` directory. If you move either checkout, update the `-I` path in the generated `build` and `test` tasks.

## Prerequisites

- **pixi** — [install it](https://pixi.sh/latest/#installation) (manages the Mojo/MAX toolchain).
- A **Mojo 1.0.0** (stable) toolchain. baldr pins the exact release it was validated against:

```toml
# pixi.toml
[dependencies]
mojo = "==1.0.0"
max  = "==26.5.0"
```

!!! warning "Pin the toolchain"
    Mojo's 1.0 betas move fast and occasionally break source between nightlies. Copy the pin above verbatim — a loose `>=` can pull a newer nightly than baldr was built for. (This is exactly the kind of rough edge these docs exist to surface: a published-package story is coming.)

## Get the source

Until baldr is a published Mojo package, you depend on its source with a relative `-I` include. Put your project next to a `mojo-bundle` checkout:

```console
$ git clone <baldr-repo> mojo-bundle
$ mkdir myapp && cd myapp
```

## Your project

```toml
# myapp/pixi.toml
[workspace]
channels  = ["https://conda.modular.com/max", "conda-forge"]
platforms = ["linux-aarch64", "linux-64"]

[tasks]
build = "mojo build src/main.mojo -I ../mojo-bundle/src -o build/app"
run   = { cmd = "build/app", depends-on = ["build"] }

[dependencies]
mojo = "==1.0.0"
max  = "==26.5.0"
```

```mojo
# myapp/src/main.mojo
from baldr.app import App, DispatchHandler
from baldr.request import Request
from baldr.response import Response

@fieldwise_init
struct MyApp(DispatchHandler, Copyable, Movable):
    def __call__(mut self, req: Request) raises -> Response:
        return Response.html("<h1>hello from baldr</h1>")

def main() raises:
    var app = App()
    app.run(MyApp(), port=8080)
```

## Build & run

```console
$ pixi run build && build/app
[baldr] listening on 0.0.0.0 port 8080

$ curl localhost:8080
<h1>hello from baldr</h1>
```

You now have a single self-contained binary at `build/app`. Copy it to any matching-arch box and run it — no Mojo, no Python, no dependencies on the target.

!!! tip "Prefer the scaffold"
    The hand-written setup above explains the underlying include-path contract. For a new app, `pixi run new -- myapp` creates the same setup plus tests, templates, static files, and the development loop.

Next: **[First Steps →](tutorial/first-steps.md)** builds a real app one layer at a time.
