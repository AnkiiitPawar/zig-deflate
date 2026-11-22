"""Checks zdeflate against other implementations.

1. Round trips through the command-line tool: zdeflate output decoded by
   classic zlib, zlib-ng and GNU gzip, and their output decoded by zdeflate,
   for every corpus file, level and format.
2. Differential testing of the decoder: 20,000 damaged or random raw
   streams, decoded by zdeflate (a ReleaseSafe build, so any out-of-bounds
   access would abort) and by classic zlib and zlib-ng. For every stream the
   decoders must agree on accept or reject, and when they accept, on the
   output and on the number of bytes the stream occupied.

    python3 scripts/corpus.py
    python3 scripts/interop.py      # builds zdeflate with -Doptimize=ReleaseSafe

Writes docs/data/differential.csv.
"""

import collections
import csv
import pathlib
import random
import struct
import subprocess
import tempfile

import build
import zlibc

LIBS = zlibc.libraries()
import gzip  # noqa: E402  (after the libraries: see zlibc.py)

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = None  # set in main: the ReleaseSafe build
CORPUS = ROOT / "corpus"
FILES = ["source.zig", "server.log", "zig.bin", "signal.f64", "random.bin"]


def zdeflate(args, data):
    return subprocess.run([str(BIN / "zdeflate")] + args, input=data, capture_output=True, check=True).stdout


def round_trips():
    count = 0
    names = list(LIBS)
    for f in FILES:
        data = (CORPUS / f).read_bytes()[: 1 << 20]
        for level in range(10):
            raw = zdeflate(["-f", "raw", f"-{level}"], data)
            for lib in LIBS.values():
                out, used = lib.inflate(raw, len(data))
                assert out == data and used == len(raw), (f, level)
            gz = zdeflate(["-f", "gzip", f"-{level}"], data)
            assert gzip.decompress(gz) == data
            gnu = subprocess.run(["gzip", "-dc"], input=gz, capture_output=True, check=True).stdout
            assert gnu == data
            count += 3
        for level in (1, 6, 9):
            for lib in LIBS.values():
                for strategy in range(5):
                    z = lib.compress(data, level, strategy)
                    assert zdeflate(["-d", "-f", "raw"], z) == data
                    count += 1
            gnu = subprocess.run(["gzip", "-c", f"-{level}", "-n"], input=data, capture_output=True, check=True).stdout
            assert zdeflate(["-d", "-f", "gzip"], gnu) == data
            count += 1
    print(f"round trips: {count} passed ({', '.join(names)}, GNU gzip)")


def mutate(rng, z):
    kind = rng.choice(["bit flips", "byte overwritten", "truncated", "byte inserted", "trailing junk", "random bytes"])
    b = bytearray(z)
    if kind == "bit flips" and b:
        for _ in range(rng.randint(1, 3)):
            b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
    elif kind == "byte overwritten" and b:
        b[rng.randrange(len(b))] = rng.randrange(256)
    elif kind == "truncated":
        b = b[: rng.randrange(len(b) + 1)]
    elif kind == "byte inserted":
        b.insert(rng.randrange(len(b) + 1), rng.randrange(256))
    elif kind == "trailing junk":
        b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
    elif kind == "random bytes":
        b = bytearray(rng.randbytes(rng.randint(1, 200)))
    return kind, bytes(b)


def differential(n=20_000, seed=1):
    rng = random.Random(seed)
    sources = [(CORPUS / f).read_bytes() for f in FILES]
    zl = next(iter(LIBS.values()))
    cases = []
    for _ in range(n):
        src = rng.choice(sources)
        start = rng.randrange(len(src))
        data = src[start:start + rng.choice([0, 1, 10, 100, 1000, 5000, 20000])]
        if rng.random() < 0.5:
            z = zdeflate(["-f", "raw", f"-{rng.choice([0, 1, 6, 9])}"], data)
        else:
            z = zl.compress(data, rng.choice([1, 6, 9]), rng.randrange(5))
        cases.append(mutate(rng, z))

    with tempfile.NamedTemporaryFile(suffix=".pack", delete=False) as fh:
        for _, s in cases:
            fh.write(struct.pack("<I", len(s)) + s)
        pack = fh.name
    ours = subprocess.run([str(BIN / "zdeflate-bench"), "--inflate", pack], capture_output=True, text=True,
                          check=True).stdout.splitlines()
    assert len(ours) == len(cases)

    tally = collections.defaultdict(collections.Counter)
    errors = collections.Counter()
    for (kind, s), line in zip(cases, ours):
        results = [lib.inflate(s) for lib in LIBS.values()]
        theirs = [None if r is None else (r[1], len(r[0]), zlib_crc(r[0])) for r in results]
        if line.startswith("ok"):
            _, used, length, crc = line.split()
            mine = (int(used), int(length), int(crc, 16))
        else:
            mine = None
            errors[line.split()[1]] += 1
        tally[kind]["cases"] += 1
        if all(t == mine for t in theirs):
            tally[kind]["both accept" if mine else "both reject"] += 1
        else:
            tally[kind]["disagree"] += 1
            print("DISAGREE", kind, s.hex()[:120], mine, theirs)
    rows = [{"damage": k, **{c: v[c] for c in ("cases", "both accept", "both reject", "disagree")}}
            for k, v in sorted(tally.items())]
    with open(ROOT / "docs" / "data" / "differential.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    total = sum(r["disagree"] for r in rows)
    print(f"differential: {n} streams against {', '.join(LIBS)}: {total} disagreements")
    for r in rows:
        print(f"  {r['damage']:18s} {r['cases']:6d} cases  {r['both accept']:6d} accepted  "
              f"{r['both reject']:6d} rejected  {r['disagree']} disagree")
    print("  zdeflate's rejections by error:", dict(errors.most_common()))
    return total


def zlib_crc(b):
    import zlib
    return zlib.crc32(b)


if __name__ == "__main__":
    BIN = build.tools("ReleaseSafe")
    round_trips()
    raise SystemExit(1 if differential() else 0)
