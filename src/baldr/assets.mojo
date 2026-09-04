"""baldr.assets — JS/CSS asset pipeline: manifest, bundling, hashing.

Phase 2.6 — JS/CSS tooling.

A pure-Mojo (no external tooling) asset pipeline:

  - `AssetRecord` / `AssetManifest` — logical name -> hashed URL mapping,
    with content-type and reverse (URL -> record) lookup for serving.
  - `content_hash` — FNV-1a 64-bit over bytes, 16 hex chars. Not
    cryptographic; sufficient for cache-busting fingerprints. (Mojo's
    stdlib has no `std.hash` yet; SRI sha256 is deferred.)
  - `bundle_js` / `bundle_css` — concat + conservative minification
    (strip comments, collapse whitespace) over byte buffers. No
    transpilation — plain JS/CSS in, one buffer out.
  - `discover_assets` / `build_assets` — walk a source dir, classify by
    extension, bundle JS/CSS, pass through binary assets (images/fonts)
    with hashes, write hashed outputs, return the manifest.

`App.assets(manifest, url_prefix)` serves manifest URLs with immutable
cache headers + ETag. For template integration, `Templates.with_manifest`
injects an `assets` dict so templates render `{{ assets["app.js"] }}`.
"""

from std.collections import Dict, List
from std.pathlib import Path


# ── Hashing (FNV-1a 64-bit) ───────────────────────────────────────────────
comptime FNV_OFFSET: UInt64 = UInt64(0xcbf29ce484222325)
comptime FNV_PRIME: UInt64 = UInt64(0x100000001b3)


def content_hash(data: List[UInt8]) -> String:
    """FNV-1a 64-bit over `data`, rendered as 16 lowercase hex chars."""
    var h: UInt64 = FNV_OFFSET
    for i in range(len(data)):
        h = h ^ UInt64(data[i])
        h = h * FNV_PRIME
    return _hex64(h)


def _hex64(v: UInt64) -> String:
    var hexdigits = String("0123456789abcdef")
    var out = String()
    # 16 nibbles, most-significant first
    var shift: Int = 60
    while shift >= 0:
        var nib = Int((v >> UInt64(shift)) & UInt64(0xf))
        out += String(hexdigits[byte=nib])
        shift -= 4
    return out^


# ── Asset records ─────────────────────────────────────────────────────────
struct AssetRecord(Copyable, Movable):
    var logical_name: String      # "app.js" — what templates refer to
    var source_path: String       # "assets/js/app.js"
    var output_path: String       # "static/app.<hash>.js"
    var url: String               # "/static/app.<hash>.js"
    var content_type: String
    var hash: String              # 16 hex chars
    var bytes: List[UInt8]        # built content (cached)

    def __init__(out self):
        self.logical_name = String()
        self.source_path = String()
        self.output_path = String()
        self.url = String()
        self.content_type = String()
        self.hash = String()
        self.bytes = List[UInt8]()


struct AssetManifest(Copyable, Movable):
    var records: List[AssetRecord]        # ordered
    var by_name: Dict[String, Int]        # logical_name -> index
    var by_url: Dict[String, Int]         # url -> index

    def __init__(out self):
        self.records = List[AssetRecord]()
        self.by_name = Dict[String, Int]()
        self.by_url = Dict[String, Int]()

    def _add(mut self, var rec: AssetRecord):
        var idx = len(self.records)
        self.by_name[rec.logical_name] = idx
        self.by_url[rec.url] = idx
        self.records.append(rec^)

    def url_for(self, logical_name: String) -> String:
        """Return the hashed URL for a logical name, or the name itself
        (un-hashed) if not in the manifest — so missing assets are visible."""
        for entry in self.by_name.items():
            if entry.key == logical_name:
                return self.records[entry.value].url
        return logical_name

    def has(self, logical_name: String) -> Bool:
        for entry in self.by_name.items():
            if entry.key == logical_name:
                return True
        return False

    def content_type_for(self, logical_name: String) -> String:
        for entry in self.by_name.items():
            if entry.key == logical_name:
                return self.records[entry.value].content_type
        return String("application/octet-stream")

    def find_by_url(self, url: String) -> Optional[AssetRecord]:
        """Reverse lookup for the asset-aware static mount."""
        for entry in self.by_url.items():
            if entry.key == url:
                return Optional[AssetRecord](self.records[entry.value].copy())
        return Optional[AssetRecord](None)

    def has_url(self, url: String) -> Bool:
        for entry in self.by_url.items():
            if entry.key == url:
                return True
        return False

    def bytes_for_url(self, url: String) -> List[UInt8]:
        for entry in self.by_url.items():
            if entry.key == url:
                return self.records[entry.value].bytes.copy()
        return List[UInt8]()

    def content_type_for_url(self, url: String) -> String:
        for entry in self.by_url.items():
            if entry.key == url:
                return self.records[entry.value].content_type
        return String("application/octet-stream")

    def hash_for_url(self, url: String) -> String:
        for entry in self.by_url.items():
            if entry.key == url:
                return self.records[entry.value].hash
        return String()


# ── Content-type ──────────────────────────────────────────────────────────
def content_type_for_ext(ext: String) -> String:
    if ext == ".js":   return String("application/javascript; charset=utf-8")
    if ext == ".css":  return String("text/css; charset=utf-8")
    if ext == ".html" or ext == ".htm": return String("text/html; charset=utf-8")
    if ext == ".json": return String("application/json; charset=utf-8")
    if ext == ".svg":  return String("image/svg+xml")
    if ext == ".png":  return String("image/png")
    if ext == ".jpg" or ext == ".jpeg": return String("image/jpeg")
    if ext == ".gif":  return String("image/gif")
    if ext == ".webp": return String("image/webp")
    if ext == ".ico":  return String("image/x-icon")
    if ext == ".woff": return String("font/woff")
    if ext == ".woff2": return String("font/woff2")
    return String("application/octet-stream")


# ── Minification ──────────────────────────────────────────────────────────
def bundle_js(var sources: List[String]) raises -> List[UInt8]:
    """Concatenate JS sources with a newline between, then strip `//` line
    comments and `/* */` block comments and collapse blank lines.

    Conservative: does not parse string literals, so a `//` inside a string
    is treated as a comment. Sufficient for v0.6 self-authored bundles;
    real minification needs a JS parser (deferred)."""
    var joined = String()
    for i in range(len(sources)):
        if i > 0:
            joined += "\n"
        joined += sources[i]
    var raw = _str_to_bytes(joined^)
    return _minify_js(raw)


def bundle_css(var sources: List[String]) raises -> List[UInt8]:
    """Concatenate CSS, strip `/* */` comments, collapse runs of whitespace,
    drop whitespace immediately before `}` and after `{` and `;`."""
    var joined = String()
    for i in range(len(sources)):
        if i > 0:
            joined += "\n"
        joined += sources[i]
    var raw = _str_to_bytes(joined^)
    return _minify_css(raw)


def _minify_js(data: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    var n = len(data)
    var i: Int = 0
    while i < n:
        # // line comment
        if i + 1 < n and data[i] == UInt8(47) and data[i + 1] == UInt8(47):
            while i < n and data[i] != UInt8(10):
                i += 1
            continue
        # /* block comment */
        if i + 1 < n and data[i] == UInt8(47) and data[i + 1] == UInt8(42):
            i += 2
            while i + 1 < n and not (data[i] == UInt8(42) and data[i + 1] == UInt8(47)):
                i += 1
            i += 2
            continue
        out.append(data[i])
        i += 1
    return _collapse_blank_lines(out^)


def _minify_css(data: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    var n = len(data)
    var i: Int = 0
    while i < n:
        # /* comment */
        if i + 1 < n and data[i] == UInt8(47) and data[i + 1] == UInt8(42):
            i += 2
            while i + 1 < n and not (data[i] == UInt8(42) and data[i + 1] == UInt8(47)):
                i += 1
            i += 2
            continue
        out.append(data[i])
        i += 1
    # collapse runs of whitespace to a single space; drop ws around { } ; ,
    return _collapse_css_ws(out^)


def _collapse_blank_lines(data: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    var n = len(data)
    var i: Int = 0
    var last_was_nl = False
    while i < n:
        var c = data[i]
        if c == UInt8(10):
            if not last_was_nl:
                out.append(c)
            last_was_nl = True
            i += 1
            continue
        if c == UInt8(13) or c == UInt8(9):
            c = UInt8(32)
        if c == UInt8(32) and last_was_nl:
            i += 1
            continue
        last_was_nl = False
        out.append(c)
        i += 1
    return out^


def _collapse_css_ws(data: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    var n = len(data)
    var i: Int = 0
    var in_ws = False
    while i < n:
        var c = data[i]
        if c == UInt8(9) or c == UInt8(10) or c == UInt8(13):
            c = UInt8(32)
        if c == UInt8(32):
            in_ws = True
            i += 1
            continue
        if in_ws:
            # only emit a space if neither neighbor is a delimiter
            var prev = UInt8(0)
            if len(out) > 0:
                prev = out[len(out) - 1]
            if prev != UInt8(123) and prev != UInt8(59) and prev != UInt8(58) and prev != UInt8(44) and c != UInt8(125) and c != UInt8(123) and c != UInt8(59) and c != UInt8(58) and c != UInt8(44):
                out.append(UInt8(32))
            in_ws = False
        out.append(c)
        i += 1
    return out^


# ── Discovery + build ─────────────────────────────────────────────────────
def _ext_of(path: String) -> String:
    var dot = path.rfind(String("."))
    if dot < 0:
        return String()
    return String(path[byte=dot:])


def _read_file_string(path: String) raises -> String:
    var p = Path(path)
    if not p.exists() or not p.is_file():
        raise Error(String("assets: source not found: ") + path)
    var b = p.read_bytes()
    return String(unsafe_from_utf8=b[:])


def _read_file_bytes(path: String) raises -> List[UInt8]:
    var p = Path(path)
    if not p.exists() or not p.is_file():
        raise Error(String("assets: source not found: ") + path)
    return p.read_bytes()


def _built_js(full: String, minify: Bool) raises -> List[UInt8]:
    if not minify:
        return _read_file_bytes(full)
    var src = _read_file_string(full)
    var sources = List[String]()
    sources.append(src^)
    return bundle_js(sources^)


def _built_css(full: String, minify: Bool) raises -> List[UInt8]:
    if not minify:
        return _read_file_bytes(full)
    var src = _read_file_string(full)
    var sources = List[String]()
    sources.append(src^)
    return bundle_css(sources^)


def build_assets(
    source_dir: String,
    output_dir: String,
    url_prefix: String = String("/static"),
    minify: Bool = True,
) raises -> AssetManifest:
    """Walk `source_dir`, bundle JS/CSS, hash, write to `output_dir`, return
    the manifest. Binary assets (images/fonts) are passed through with hashes.

    Convention: one JS bundle per source `.js` file (named after it), and
    one CSS bundle per `.css` file. Pass-through for other extensions.
    """
    var manifest = AssetManifest()
    var src = Path(source_dir)
    if not src.exists() or not src.is_dir():
        raise Error(String("assets: source dir not found: ") + source_dir)

    _walk_and_build(source_dir, source_dir, output_dir, url_prefix, minify, manifest)
    return manifest^


def _walk_and_build(
    root: String,
    dir: String,
    output_dir: String,
    url_prefix: String,
    minify: Bool,
    mut manifest: AssetManifest,
) raises:
    var p = Path(dir)
    for var child in p.listdir():
        # child.path is just the basename; build the full path from dir.
        var name = String(child.path)
        var slash = name.rfind(String("/"))
        if slash >= 0:
            # dev2026080106 aliasing rule: materialise before self-assign.
            var _name_s = String(name[byte=slash + 1:])
            name = _name_s^
        if name == "." or name == ".." or name == ".git" or name == "node_modules":
            continue
        var full = dir
        if full.byte_length() > 0 and String(full[byte=full.byte_length() - 1:]) != "/":
            full += "/"
        full += name
        # listdir entries have unreliable is_dir()/is_file(); use a fresh Path.
        var fresh = Path(full)
        if fresh.is_dir():
            _walk_and_build(root, full^, output_dir, url_prefix, minify, manifest)
            continue
        if not fresh.is_file():
            continue
        var ext = _ext_of(full)
        var rel = String(full[byte=root.byte_length():])
        if rel.byte_length() > 0 and rel[byte=0:1] == "/":
            # dev2026080106 aliasing rule: materialise before self-assign.
            var _rel_s = String(rel[byte=1:])
            rel = _rel_s^
        var logical = rel

        if ext == ".js":
            var built = _built_js(full, minify)
            _record(manifest, logical, full, built^, ext, output_dir, url_prefix)
        elif ext == ".css":
            var built = _built_css(full, minify)
            _record(manifest, logical, full, built^, ext, output_dir, url_prefix)
        else:
            # binary / other: pass through with a hash
            var built = _read_file_bytes(full)
            _record(manifest, logical, full, built^, ext, output_dir, url_prefix)


def _record(
    mut manifest: AssetManifest,
    logical: String,
    source_path: String,
    var built: List[UInt8],
    ext: String,
    output_dir: String,
    url_prefix: String,
) raises:
    var h = content_hash(built)
    var base = logical
    # strip directory part for the output filename
    var slash = base.rfind(String("/"))
    if slash >= 0:
        # dev2026080106 aliasing rule: materialise before self-assign.
        var _base_s = String(base[byte=slash + 1:])
        base = _base_s^
    var dot = base.rfind(String("."))
    var stem = base
    if dot >= 0:
        stem = String(base[byte=0:dot])
    var hashed_name = stem + "." + h + ext
    var out_path = output_dir
    if out_path.byte_length() > 0 and String(out_path[byte=out_path.byte_length() - 1:]) != "/":
        out_path += "/"
    out_path += hashed_name

    # write the built file (write_bytes truncates/overwrites)
    var outp = Path(out_path)
    outp.write_bytes(built)

    var rec = AssetRecord()
    rec.logical_name = logical
    rec.source_path = source_path
    rec.output_path = out_path
    var prefix = url_prefix
    if prefix.byte_length() > 0 and String(prefix[byte=prefix.byte_length() - 1:]) != "/":
        prefix += "/"
    rec.url = prefix + hashed_name
    rec.content_type = content_type_for_ext(ext)
    rec.hash = h
    rec.bytes = built^
    manifest._add(rec^)


# ── helpers ───────────────────────────────────────────────────────────────
def _str_to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def manifest_to_context(manifest: AssetManifest) -> Dict[String, String]:
    """Build a logical-name -> URL map for template contexts.

    Usage: `ctx.set("assets", Value.string_dict(manifest_to_context(m)))` so
    templates render `{{ assets["app.js"] }}`. (A custom `|asset` filter would
    need a filter registry the v0.1 evaluator doesn't have; the dict approach
    works with the existing dotted-access evaluator.)
    """
    var out = Dict[String, String]()
    for i in range(len(manifest.records)):
        ref r = manifest.records[i]
        out[r.logical_name] = r.url
    return out^
