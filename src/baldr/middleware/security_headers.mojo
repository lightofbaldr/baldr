"""baldr.middleware.security_headers — defense-in-depth headers.

Adds the same five headers a defensible deployment behind a reverse
proxy still wants set explicitly: prevents MIME sniffing, frame
embedding, cross-origin referrer leak, geolocation/microphone/camera
access, and locks down resource origins via CSP.

Pattern:
    var resp = my_handler(req)
    return apply_security_headers(resp)
"""

from ..response import Response


# CSP allows local resources, Google Fonts, inline styles, and self
# data: images. Tighten or replace via the `csp=` override for apps
# with different asset surfaces.
comptime DEFAULT_CSP: String = String(
    "default-src 'self'; "
    "style-src 'self' https://fonts.googleapis.com 'unsafe-inline'; "
    "font-src 'self' https://fonts.gstatic.com; "
    "script-src 'self'; "
    "img-src 'self' data:; "
    "connect-src 'self'"
)


def apply_security_headers(
    var resp: Response,
    csp: String = DEFAULT_CSP,
) -> Response:
    """Append the five standard hardening headers to `resp`."""
    return resp \
        .with_header(String("X-Content-Type-Options"), String("nosniff")) \
        .with_header(String("X-Frame-Options"), String("DENY")) \
        .with_header(String("Referrer-Policy"), String("no-referrer")) \
        .with_header(String("Content-Security-Policy"), csp) \
        .with_header(
            String("Permissions-Policy"),
            String("geolocation=(), microphone=(), camera=()"))
