# Deploy

Here's the good part. A baldr app is **one native binary plus a static directory**. There's no runtime to install, no interpreter to match versions with, no `requirements.txt` to resolve on the box. You copy two things — `app` and `static/` — and run `./app`.

That makes the deploy story short enough to fit on one page. This is it.

## What ships

```
build/app          # your compiled binary — the entire server
static/            # files you serve verbatim (optional)
templates/         # only if you render templates at runtime (optional)
```

The binary already contains your handler, the router, the HTTP/1.1 parser, the JSON codec, the template engine — everything. `static/` and `templates/` are just data the binary reads at runtime. Copy them alongside it, or bake them into the image (below).

!!! note "The binary is native code"
    `pixi run build` produces a real ELF executable for **one CPU architecture**. It is not portable across arches — an x86-64 binary will not run on an ARM box and vice-versa. See [Cross-arch](#cross-arch-build-on-the-target) before you copy a binary to a different machine.

## A `FROM scratch` Docker image

Because there's no runtime, the image is essentially just your binary. Build in a Mojo-capable stage, then copy the one artifact into an empty final stage:

```dockerfile
# ── build stage: has the Mojo toolchain via pixi ──────────────
FROM ghcr.io/prefix-dev/pixi:latest AS build
WORKDIR /src
COPY . .
# builds your app to build/app (see get-started for the pixi task)
RUN pixi run build

# ── final stage: nothing but your binary + assets ─────────────
FROM scratch
COPY --from=build /src/build/app /app
COPY --from=build /src/static /static
EXPOSE 8080
ENTRYPOINT ["/app"]
```

```console
$ docker build -t myapp .
$ docker run --rm -p 8080:8080 myapp
[baldr] listening on 0.0.0.0 port 8080
```

The final image is your binary and your assets — a few MB, no OS, no Python, nothing to CVE-scan on the language runtime because there isn't one.

!!! tip "`scratch` vs. distroless"
    `FROM scratch` is the smallest possible image, but it has **no shell, no `libc` niceties, no CA certificates, no timezone data**. That's fine for a self-contained server that only accepts HTTP. If your handler makes *outbound* TLS calls, or you want a shell for `docker exec` debugging, swap the final stage to a distroless base instead:

    ```dockerfile
    FROM gcr.io/distroless/cc-debian12
    COPY --from=build /src/build/app /app
    COPY --from=build /src/static /static
    EXPOSE 8080
    ENTRYPOINT ["/app"]
    ```

    `cc-debian12` carries `glibc` and CA certs, still no shell by default, and is a handful of MB. When in doubt, start here and shrink to `scratch` once you know your binary has no dynamic dependencies (`ldd build/app` tells you).

## Config from the environment

Hardcoding `port=8080` in `main()` is fine for the tutorial. In production you want the port (and friends) to come from the environment, the way a twelve-factor app does. baldr reads them for you through `ServerConfig.from_env`:

```mojo
from baldr.app import App
from baldr.config import ServerConfig
from myapp.handler import MyApp   # your DispatchHandler

def main() raises:
    var cfg = ServerConfig.from_env()
    var app = App()
    app.static("/static", cfg.static_dir)
    app.run(MyApp(), host=cfg.host, port=cfg.port)
```

`from_env()` loads a `.env` file if one is present (real environment variables win over `.env`), then reads these variables — **each has a default, so nothing is required**:

| Env var | Field | Default | Notes |
|---|---|---|---|
| `HOST` | `cfg.host` | `0.0.0.0` | bind address you pass to `run` |
| `PORT` | `cfg.port` | `8080` | listen port |
| `DEBUG` | `cfg.debug` | `False` | your handler can branch on it |
| `WORKERS` | `cfg.workers` | `4` | prefork worker count (see below) |
| `MAX_BODY_BYTES` | `cfg.max_body_bytes` | `10485760` | 10 MiB request-body cap |
| `STATIC_DIR` | `cfg.static_dir` | `./static` | dir you mount with `app.static(...)` |
| `TEMPLATE_DIR` | `cfg.template_dir` | `./templates` | dir your template loader reads |

The real signature is `ServerConfig.from_env() raises -> ServerConfig` — a `@staticmethod` that returns the struct. Every field is a plain `String`, `Int`, or `Bool`.

!!! note "`from_env` is a static method — Mojo's `@staticmethod`"
    You call it on the type (`ServerConfig.from_env()`), not on an instance — the same idea as Python's `@staticmethod`. New to Mojo's `def`/`raises`/`String` spellings? The one-page [Mojo primer](mojo-primer.md) covers them.

!!! warning "`from_env` gives you values — *you* wire them in"
    This is a genuine rough edge today. `ServerConfig.from_env()` **reads and parses** all seven variables, but `App.run` only takes `host` and `port`. So `HOST` and `PORT` flow through cleanly, but `DEBUG`, `WORKERS`, `MAX_BODY_BYTES`, `STATIC_DIR`, and `TEMPLATE_DIR` are handed to *you* as struct fields — the framework does not apply them automatically. You pass `cfg.static_dir` to `app.static(...)`, branch on `cfg.debug` in your own code, and pass `cfg.workers` to the prefork entry point yourself. A future `App.run(config=...)` that consumes the whole struct is on the punch-list.

A `.env` file for local runs is just `KEY=value` lines:

```console
# .env — loaded by from_env() when present
HOST=0.0.0.0
PORT=8080
WORKERS=8
STATIC_DIR=./static
```

With Docker you'd pass the same values as `-e PORT=9000` flags or an `--env-file`, and skip the `.env` file entirely.

## Running the prefork pool in production

The single-process `app.run(...)` from the tutorial handles one request at a time. For real traffic you want the **prefork worker pool** — N processes sharing one listening socket, the kernel load-balancing across them. Wire `cfg.workers` into it:

```mojo
from baldr.concurrency import run_concurrent
from baldr.config import ServerConfig
from myapp.handler import MyApp

def main() raises:
    var cfg = ServerConfig.from_env()
    run_concurrent(MyApp(), host=cfg.host, port=cfg.port, workers=cfg.workers)
```

The signature is `run_concurrent[H: DispatchHandler & Copyable](var handler, host, port, workers)`. Each worker gets its own **copy** of your handler, so there's no shared mutable state and no locking.

!!! note "`[H: DispatchHandler & Copyable]` — a compile-time bound"
    The bracket part is a Mojo compile-time parameter: it says "`H` is some handler type that is both a `DispatchHandler` and `Copyable`," resolved at build time. You never write the `[H]` yourself — the compiler infers it from the handler you pass. The [Mojo primer](mojo-primer.md) has the one-paragraph version.

!!! warning "Per-worker handler copies diverge"
    Because each of the `WORKERS` processes runs its own `handler.copy()`, any state a handler mutates in `self` (an in-memory counter, a cache) is **per-worker and will diverge**. That's fine for stateless handlers — static files, reads, stateless APIs parallelize for free. If you need shared state, move it into `baldr.queue` or an external store and keep the per-process handler stateless. This is the deliberate trade prefork makes; see [Concurrency](guide/concurrency.md) for the why.

In the Dockerfile, point the entrypoint at the binary that calls `run_concurrent`, and set `WORKERS` at runtime:

```console
$ docker run --rm -p 8080:8080 -e WORKERS=8 myapp
[baldr] prefork: 8 workers on 0.0.0.0 port 8080 (parent pid 1)
```

## A systemd unit

On a plain VM without Docker, the binary is a normal executable — systemd supervises it like any other daemon. Copy `app` and `static/` to the host, drop this at `/etc/systemd/system/myapp.service`:

```toml
[Unit]
Description=myapp (baldr)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/myapp
ExecStart=/opt/myapp/app
Environment=PORT=8080
Environment=WORKERS=8
Environment=STATIC_DIR=/opt/myapp/static
# or, instead of the Environment= lines:
# EnvironmentFile=/opt/myapp/.env
Restart=on-failure
DynamicUser=yes

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now myapp
$ journalctl -u myapp -f
[baldr] prefork: 8 workers on 0.0.0.0 port 8080 (parent pid 4127)
```

`WorkingDirectory` matters: `from_env()` looks for `.env` and the default `./static` relative to the process's working directory, so set it to wherever you unpacked the app. `DynamicUser=yes` runs it as an ephemeral unprivileged user — the binary needs no special privileges to bind a high port.

!!! tip "Binding port 80/443 directly"
    A non-root process can't bind ports below 1024. Don't run the whole thing as root to get there — either keep baldr on `8080` behind a reverse proxy (next section, and what you almost certainly want), or grant just the one capability with `AmbientCapabilities=CAP_NET_BIND_SERVICE` in the `[Service]` block.

## Cross-arch: build on the target

baldr's whole platform list is two Linux arches:

```toml
# pixi.toml
platforms = ["linux-aarch64", "linux-64"]
```

The binary `pixi run build` emits is native machine code for **the architecture you built on**. There is no fat binary and no cross-compile flag in the tutorial flow. So:

- Building on an Apple-silicon or Graviton/ARM box → an **aarch64** binary. It runs on ARM servers, not on x86.
- Building on an Intel/AMD box → an **x86-64** binary. It runs on x86 servers, not on ARM.

The clean way to get this right is to **build in the same environment you deploy to**. The multi-stage Dockerfile above does exactly that when you build the image *for* the target arch:

```console
# build an aarch64 image on an x86 laptop, using buildx emulation
$ docker buildx build --platform linux/arm64 -t myapp:arm64 .

# build a native x86 image
$ docker buildx build --platform linux/amd64 -t myapp:amd64 .
```

If you're copying a bare binary to a VM instead of shipping an image, build it on a machine of the same arch as that VM (or inside a container of that arch). Copy an aarch64 binary onto an x86 host and it simply won't execute.

!!! note "One source, two arches"
    You don't maintain two codebases — the *same* Mojo source vectorizes to Neon on ARM and AVX2 on x86. Cross-arch is purely a build-time concern: compile once per arch you deploy to. Nothing in your handler changes.

## TLS: not baldr's job

Be clear-eyed about this one. **baldr speaks HTTP/1.1 in plaintext.** It does not terminate TLS, it has no certificate loading, and it does not do HTTP/2 or HTTP/3. Do not put it directly on the public internet on port 443.

The right architecture is the standard one: a **TLS-terminating reverse proxy** in front, forwarding cleartext HTTP to baldr on localhost. Caddy is the least-effort option because it obtains and renews certificates automatically:

```console
# Caddyfile — automatic HTTPS, proxy to baldr on :8080
example.com {
    reverse_proxy 127.0.0.1:8080
}
```

nginx does the same with explicit certs:

```console
# /etc/nginx/conf.d/myapp.conf
server {
    listen 443 ssl;
    server_name example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
    }
}
```

!!! warning "Bind baldr to localhost behind the proxy"
    When a proxy fronts baldr, set `HOST=127.0.0.1` so the app only accepts connections from the proxy on the same host, never directly from the network. The proxy owns `:443` and TLS; baldr owns the application. This split is deliberate — TLS termination, cert rotation, and HTTP/2 are mature, security-sensitive problems a reverse proxy already solves well, and keeping them out of baldr keeps the request path small and auditable. Native TLS is not currently on baldr's roadmap; the reverse proxy is the supported answer.

## Deploy checklist

- [ ] Build the binary **on the target architecture** (or `buildx --platform`).
- [ ] Copy `build/app` and `static/` together.
- [ ] Set `PORT`, `WORKERS`, `HOST` via env (or `.env` / `EnvironmentFile`).
- [ ] Serve with `run_concurrent(...)` for real traffic, not single-process `run`.
- [ ] Put Caddy or nginx in front for TLS; bind baldr to `127.0.0.1`.
- [ ] Supervise with systemd (`Restart=on-failure`) or your container orchestrator.

That's a production deploy: one binary, one static dir, one reverse proxy. No runtime on the box, nothing to `pip install`, nothing to keep patched but your own code and the proxy.
