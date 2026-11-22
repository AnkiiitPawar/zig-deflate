"""Raw DEFLATE through a zlib shared library, called with ctypes.

Python's own zlib module may be linked against zlib-ng; loading a library by
path makes it possible to compare against classic zlib and zlib-ng side by
side, through the same calls.
"""

import ctypes

Z_FINISH, Z_NO_FLUSH = 4, 0
Z_OK, Z_STREAM_END, Z_BUF_ERROR = 0, 1, -5


class ZStream(ctypes.Structure):
    _fields_ = [
        ("next_in", ctypes.c_void_p), ("avail_in", ctypes.c_uint), ("total_in", ctypes.c_ulong),
        ("next_out", ctypes.c_void_p), ("avail_out", ctypes.c_uint), ("total_out", ctypes.c_ulong),
        ("msg", ctypes.c_char_p), ("state", ctypes.c_void_p),
        ("zalloc", ctypes.c_void_p), ("zfree", ctypes.c_void_p), ("opaque", ctypes.c_void_p),
        ("data_type", ctypes.c_int), ("adler", ctypes.c_ulong), ("reserved", ctypes.c_ulong),
    ]


class Zlib:
    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        self.lib.zlibVersion.restype = ctypes.c_char_p
        self.version = self.lib.zlibVersion()
        self.lib.deflateBound.restype = ctypes.c_ulong
        self.lib.deflateBound.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

    def compress(self, data, level, strategy=0):
        """Raw DEFLATE (window bits -15, memLevel 8). Strategies: 0 default,
        1 filtered, 2 Huffman only, 3 RLE, 4 fixed codes only."""
        s = ZStream()
        rc = self.lib.deflateInit2_(ctypes.byref(s), level, 8, -15, 8, strategy, self.version, ctypes.sizeof(s))
        assert rc == Z_OK, rc
        try:
            cap = self.lib.deflateBound(ctypes.byref(s), len(data))
            out = ctypes.create_string_buffer(cap)
            src = ctypes.create_string_buffer(data, len(data))
            s.next_in, s.avail_in = ctypes.addressof(src), len(data)
            s.next_out, s.avail_out = ctypes.addressof(out), cap
            rc = self.lib.deflate(ctypes.byref(s), Z_FINISH)
            assert rc == Z_STREAM_END, rc
            return out.raw[: s.total_out]
        finally:
            self.lib.deflateEnd(ctypes.byref(s))

    def inflate(self, data, size_hint=None):
        """Returns (output, bytes consumed) for a complete stream, or None if
        the library rejects the data or it ends before the stream does."""
        s = ZStream()
        rc = self.lib.inflateInit2_(ctypes.byref(s), -15, self.version, ctypes.sizeof(s))
        assert rc == Z_OK, rc
        try:
            src = ctypes.create_string_buffer(data, len(data))
            s.next_in, s.avail_in = ctypes.addressof(src), len(data)
            chunks = []
            chunk = max(size_hint or 0, 1 << 16)
            while True:
                out = ctypes.create_string_buffer(chunk)
                s.next_out, s.avail_out = ctypes.addressof(out), chunk
                rc = self.lib.inflate(ctypes.byref(s), Z_NO_FLUSH)
                chunks.append(out.raw[: chunk - s.avail_out])
                if rc == Z_STREAM_END:
                    return b"".join(chunks), s.total_in
                if rc != Z_OK and rc != Z_BUF_ERROR:
                    return None
                if s.avail_out != 0:  # all input used, stream not finished
                    return None
        finally:
            self.lib.inflateEnd(ctypes.byref(s))


CLASSIC = "/lib/x86_64-linux-gnu/libz.so.1"
NG = "/usr/local/lib/libz.so.1"


def libraries():
    """The libraries present here, by display name."""
    found = {}
    for name, path in (("zlib", CLASSIC), ("zlib-ng", NG)):
        try:
            lib = Zlib(path)
        except OSError:
            continue
        version = lib.version.decode().removesuffix(".zlib-ng")  # zlib-ng's compat build says "1.3.1.zlib-ng"
        found[f"{name} {version}"] = lib
    return found
