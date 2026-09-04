# Get Started

baldr is a Mojo library. You need the Mojo toolchain (via [pixi](https://pixi.sh)), the baldr source on disk, and one `-I` include flag. That's it — the output is a single native binary.

!!! tip "New to Mojo? Read [Mojo in 5 Minutes](mojo-primer.md) first."
    Coming from Python, six small language differences explain everything you'll see in the examples. Five-minute read, and the rest of the docs click into place.

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
    App().run(MyApp(), port=8080)
```

## Build & run

```console
$ pixi run build && build/app
[baldr] listening on 0.0.0.0 port 8080

$ curl localhost:8080
<h1>hello from baldr</h1>
```

You now have a single self-contained binary at `build/app`. Copy it to any matching-arch box and run it — no Mojo, no Python, no dependencies on the target.

!!! tip "Coming: `baldr new`"
    The `git clone` + hand-written `pixi.toml` above is the honest primitive today. A `baldr new myapp` scaffold + a `pixi run dev` live-reload loop are on the near-term roadmap — they'll wrap exactly this so day one is one command.

Next: **[First Steps →](tutorial/first-steps.md)** builds a real app one layer at a time.
