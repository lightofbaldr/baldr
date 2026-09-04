"""baldr.lifecycle — on_startup / on_shutdown hooks.

Phase 2.8 — lifecycle. Lets an app initialize resources (DB connections,
warm caches, build the asset manifest) before serving and drain them on
exit. `App.run` catches SIGTERM/SIGINT process-wide with a minimal C-ABI
handler that writes one byte to a self-pipe; App logic polls that pipe only
at safe boundaries. `on_startup` runs once in the parent; after worker drain
and reap, `on_shutdown` runs once in the parent before `run` returns normally.
"""


trait LifecycleHooks(Movable, Deinitable):
    """Called once before the accept loop and once after it exits.

    Conform a struct and hand it to `App(lifecycle=...)` (or the deprecated
    `App.run_full`). `on_startup` is the place to build the asset manifest,
    open DB connections, warm caches; `on_shutdown` drains them. Both may
    raise."""
    def on_startup(mut self) raises: ...
    def on_shutdown(mut self) raises: ...


@fieldwise_init
struct NoLifecycle(LifecycleHooks, Defaultable, Copyable, Movable):
    """`App()`'s default: no startup or shutdown work."""
    var _unused: Int

    def __init__(out self):
        self._unused = 0

    def on_startup(mut self) raises:
        pass

    def on_shutdown(mut self) raises:
        pass
