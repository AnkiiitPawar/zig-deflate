"""Compressed size and speed of zdeflate, classic zlib and zlib-ng on the
corpus, single-threaded, raw DEFLATE at levels 1, 6 and 9. Writes
docs/data/bench.csv.

    python3 scripts/corpus.py
    python3 scripts/bench.py

zdeflate is built with -Doptimize=ReleaseFast. Each speed is the best of
three passes over everything, and within a pass the best of at least three
runs (more, up to a second's worth), which irons out most of the noise of a
shared machine. The libraries are called through ctypes on the same buffers.
"""

import csv
import io
import pathlib
import platform
import subprocess
import time

import build
import zlibc  # load the libraries before anything imports Python's zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS = ROOT / "corpus"
FILES = ["source.zig", "server.log", "zig.bin", "signal.f64", "random.bin"]
LEVELS = [1, 6, 9]


def best_time(fn, min_runs=3, budget=1.0, max_runs=20):
    best, spent, runs = float("inf"), 0.0, 0
    while runs < min_runs or (spent < budget and runs < max_runs):
        t0 = time.perf_counter()
        fn()
        dt = time.perf_counter() - t0
        best, spent, runs = min(best, dt), spent + dt, runs + 1
    return best


def measure(bench):
    rows = []
    out = subprocess.run([str(bench)] + [str(CORPUS / f) for f in FILES], capture_output=True, text=True,
                         check=True).stdout
    for r in csv.DictReader(io.StringIO(out)):
        rows.append({"impl": "zdeflate", **{k: r[k] for k in
                     ("file", "level", "in_bytes", "out_bytes", "compress_mb_s", "decompress_mb_s")}})
    for name, lib in zlibc.libraries().items():
        for f in FILES:
            data = (CORPUS / f).read_bytes()
            mb = len(data) / 1e6
            for level in LEVELS:
                z = lib.compress(data, level)
                back, used = lib.inflate(z, len(data))
                assert back == data and used == len(z)
                tc = best_time(lambda: lib.compress(data, level))
                td = best_time(lambda: lib.inflate(z, len(data)), max_runs=50)
                rows.append({"impl": name, "file": f, "level": str(level), "in_bytes": str(len(data)),
                             "out_bytes": str(len(z)), "compress_mb_s": f"{mb / tc:.2f}",
                             "decompress_mb_s": f"{mb / td:.2f}"})
    return rows


def main(passes=3):
    bench = build.tools("ReleaseFast") / "zdeflate-bench"
    best = {}
    for p in range(passes):
        for r in measure(bench):
            key = (r["impl"], r["file"], r["level"])
            if key in best:
                assert best[key]["out_bytes"] == r["out_bytes"]
                for k in ("compress_mb_s", "decompress_mb_s"):
                    if float(r[k]) > float(best[key][k]):
                        best[key][k] = r[k]
            else:
                best[key] = r
        print(f"pass {p + 1} of {passes} done", flush=True)
    rows = list(best.values())
    path = ROOT / "docs" / "data" / "bench.csv"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("wrote", path, "on", platform.processor() or platform.machine())


if __name__ == "__main__":
    main()
