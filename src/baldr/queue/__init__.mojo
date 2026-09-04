"""baldr.queue — in-process CPU/SIMD storage behind one Queue/KV/Tasks API.

Phase 3 shipped `CpuQueue`. Post-Phase-6 ships the public `Queue`
facade in `api.mojo`, with env-driven backend selection via
`BALDR_QUEUE_BACKEND`. The in-process GPU backend was REMOVED on
2026-08-03 and lives in mojo-gpuq: a web framework does not need
device memory for queue storage, and it carried baldr's only
CUDA/dlopen surface. GPU work belongs in a subsystem over the wire.

    from baldr.queue import Queue, CpuQueue, Match
"""

from .api import Queue
from .cpu import CpuQueue, Match
