"""baldr.lifecycle — on_startup / on_shutdown hooks.

Phase 2.8 — lifecycle. Lets an app initialize resources (DB connections,
warm caches, build the asset manifest) before serving and drain them on
exit. Mojo 1.0 has no portable signal-handling story without FFI to
`sigaction`, so `run_full` calls `on_startup` before the accept loop and
`on_shutdown` in a `finally` block (covers normal Ctrl-C interrupts that
unwind the loop with an exception). A future Mojo release with stable
signal FFI can install a real SIGTERM/SIGINT handler.
"""


trait LifecycleHooks(Movable, Deinitable):
    """Called once before the accept loop and once after it exits.

    Conform a struct and pass it to `App.run_full`. `on_startup` is the
    place to build the asset manifest, open DB connections, warm caches;
    `on_shutdown` drains them. Both may raise."""
    def on_startup(mut self) raises: ...
    def on_shutdown(mut self) raises: ...
