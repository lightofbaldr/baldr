"""baldr.middleware.logger — minimal request-log line.

Mirrors Apache's combined-log shape, trimmed to the fields useful for
single-binary deployments. Pure helpers — `format_log_line()` returns
the string for callers that want to route it; `log_request()` prints it
to stdout for the default case.
"""

from std.time import perf_counter_ns

from ..request import Request
from ..response import Response


def format_log_line(req: Request, resp: Response, start_ns: UInt) -> String:
    """Render one request as a single log line.

    Format:  METHOD PATH → STATUS  (BYTES bytes, MILLIS ms)
    """
    var end_ns = perf_counter_ns()
    var elapsed_us = (end_ns - start_ns) // 1000
    var elapsed_ms_int = elapsed_us // 1000
    var elapsed_ms_frac = elapsed_us % 1000

    var line = req.method + " " + req.path + " → " + String(resp.status)
    line += "  (" + String(len(resp.body)) + " bytes, "
    line += String(elapsed_ms_int) + "."
    # zero-pad the microsecond fraction to 3 digits
    if elapsed_ms_frac < 10:
        line += "00"
    elif elapsed_ms_frac < 100:
        line += "0"
    line += String(elapsed_ms_frac) + " ms)"
    return line^


def log_request(req: Request, resp: Response, start_ns: UInt):
    """Print one request to stdout via `format_log_line`."""
    print(format_log_line(req, resp, start_ns))
