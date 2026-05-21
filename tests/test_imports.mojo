"""Phase 1 import smoke test.

Confirms every vendored module compiles and exports at least one
symbol under the `baldr.*` namespace. Public API (Phase 2) will replace
this with proper integration tests.
"""

from baldr.http import handle_request, DEFAULT_PORT as HTTP_DEFAULT_PORT
from baldr.serve import ServeConfig
from baldr.template import render, evaluate, Value, Template
from baldr.json import parse, dumps, JsonValue
from baldr.queue.gpu import DEFAULT_PORT as GPUQ_DEFAULT_PORT
from baldr.queue.client import gpuq_claim


def main() raises:
    print("[ok] baldr.http imports — DEFAULT_PORT =", HTTP_DEFAULT_PORT)
    print("[ok] baldr.serve imports — ServeConfig available")
    print("[ok] baldr.template imports — render/evaluate/Value/Template")
    print("[ok] baldr.json imports — parse/dumps/JsonValue")
    print("[ok] baldr.queue.gpu imports — DEFAULT_PORT =", GPUQ_DEFAULT_PORT)
    print("[ok] baldr.queue.client imports — gpuq_claim")
    print("---")
    print("6 / 6 modules import cleanly")
