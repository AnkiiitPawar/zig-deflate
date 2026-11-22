"""Builds the benchmark corpus in corpus/ (not in git): five 4 MiB files of
different character. Everything is either generated from a fixed seed or
taken from the Zig 0.17.1 distribution, so the files can be rebuilt exactly.

    python3 scripts/corpus.py
"""

import math
import pathlib
import random
import struct
import subprocess

import build

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "corpus"
SIZE = 4 << 20


def zig_root():
    env = subprocess.run(build.zig() + ["env"], capture_output=True, text=True, check=True).stdout
    for line in env.splitlines():
        if ".lib_dir" in line:
            return pathlib.Path(line.split('"')[-2]).parent
    raise SystemExit("cannot find the Zig installation")


def source(root):
    """The Zig standard library's sources, concatenated in path order."""
    out = bytearray()
    for p in sorted((root / "lib" / "std").rglob("*.zig")):
        out += p.read_bytes()
        if len(out) >= SIZE:
            break
    return bytes(out[:SIZE])


def binary(root):
    """Machine code: the start of the zig compiler's own executable."""
    return (root / "zig").read_bytes()[:SIZE]


def server_log():
    """Web server access log lines (synthetic)."""
    rng = random.Random(1)
    ips = [f"10.{rng.randrange(256)}.{rng.randrange(256)}.{rng.randrange(1, 255)}" for _ in range(400)]
    paths = ["/", "/index.html", "/api/v1/orders", "/api/v1/orders/{}", "/static/app.{}.js", "/img/{}.png",
             "/login", "/search?q={}", "/api/v1/users/{}/cart"]
    agents = ["Mozilla/5.0 (X11; Linux x86_64)", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
              "curl/8.5.0", "Go-http-client/1.1", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"]
    t = 1_700_000_000
    lines = []
    size = 0
    while size < SIZE:
        t += rng.randrange(3)
        path = rng.choice(paths).format(rng.randrange(100000))
        status = rng.choices([200, 304, 404, 500], [90, 6, 3, 1])[0]
        line = (f'{rng.choice(ips)} - - [{t}] "GET {path} HTTP/1.1" {status} {rng.randrange(200, 90000)} '
                f'"-" "{rng.choice(agents)}"\n')
        lines.append(line)
        size += len(line)
    return "".join(lines).encode()[:SIZE]


def signal():
    """A sampled measurement: float64 values of a noisy damped oscillation."""
    rng = random.Random(2)
    n = SIZE // 8
    vals = [math.exp(-i / n) * math.sin(i * 0.01) + rng.gauss(0, 1e-3) for i in range(n)]
    return struct.pack(f"<{n}d", *vals)


def noise():
    return random.Random(3).randbytes(SIZE)


def main():
    OUT.mkdir(exist_ok=True)
    root = zig_root()
    files = {"source.zig": source(root), "server.log": server_log(), "signal.f64": signal(),
             "zig.bin": binary(root), "random.bin": noise()}
    for name, data in files.items():
        (OUT / name).write_bytes(data)
        print(f"{name:12s} {len(data):>9,d} bytes")


if __name__ == "__main__":
    main()
