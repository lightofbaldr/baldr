"""baldr.queue — GPU and CPU backends behind one Queue/KV/Tasks API.

Phase 3 shipped `CpuQueue`. Post-Phase-6 ships the public `Queue`
facade in `api.mojo`, with env-driven backend selection via
`BALDR_QUEUE_BACKEND`. The in-process GPU backend (extracted from
the vendored TCP-server `gpu.mojo`) lands in v0.2; until then `gpu`
storage is reachable via `Queue.remote()` against the TCP server.

    from baldr.queue import Queue, CpuQueue, Match
"""

from .api import Queue
from .cpu import CpuQueue, Match
