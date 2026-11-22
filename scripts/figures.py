"""Figures for the README.

    python3 scripts/corpus.py && python3 scripts/bench.py   # docs/data/bench.csv
    python3 scripts/figures.py
"""

import collections
import csv
import math
import pathlib
import subprocess
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyBboxPatch  # noqa: E402

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import build  # noqa: E402
import tokens  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
SURFACE, INK, INK2, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
LIGHT = "#cde2fb"
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE, "axes.edgecolor": AXIS,
    "axes.labelcolor": INK2, "axes.titlecolor": INK, "axes.titlesize": 11, "axes.titleweight": "bold",
    "xtick.color": INK2, "ytick.color": INK2, "font.size": 9.5, "axes.grid": True, "grid.color": GRID,
    "grid.linewidth": 0.6, "axes.spines.top": False, "axes.spines.right": False, "legend.frameon": False,
})

TEXT = (b"How much wood would a woodchuck chuck if a woodchuck could chuck wood? A woodchuck would chuck as much "
        b"wood as a woodchuck could chuck if a woodchuck could chuck wood.")


BIN = None  # set in main


def zdeflate(args, data):
    return subprocess.run([str(BIN / "zdeflate")] + args, input=data, capture_output=True, check=True).stdout


def save(fig, name):
    fig.savefig(DOCS / name, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote", DOCS / name)


def lz77():
    """The tokens zdeflate chooses for a tongue twister: literals and copies."""
    z = zdeflate(["-f", "raw", "-9"], TEXT)
    out, blocks = tokens.parse(z)
    assert out == TEXT
    toks = blocks[0]["tokens"]
    per_row, cw, rh = 43, 1.0, 2.4
    rows = math.ceil(len(TEXT) / per_row)
    fig, ax = plt.subplots(figsize=(13, 0.62 * rows * rh + 0.6))

    def cell(i):
        return (i % per_row) * cw, -(i // per_row) * rh

    shade = 0
    label_end = {}  # (row, line) -> x where the last label there ends
    for t in toks:
        start = t[-1]
        n = 1 if t[0] == "lit" else t[1]
        color = "#ecebe6" if t[0] == "lit" else (BLUE if shade % 2 == 0 else "#1c5cab")
        if t[0] == "match":
            shade += 1
        # A token may wrap to the next row: draw one box per row piece.
        i = start
        while i < start + n:
            x, y = cell(i)
            m = min(start + n - i, per_row - i % per_row)
            ax.add_patch(FancyBboxPatch((x + 0.06, y - 0.42), m * cw - 0.12, 0.84,
                                        boxstyle="round,pad=0,rounding_size=0.12", facecolor=color, edgecolor="none"))
            for k in range(m):
                ch = chr(TEXT[i + k])
                ax.text(x + k * cw + 0.5, y, "·" if ch == " " else ch, ha="center", va="center", family="monospace",
                        fontsize=10.5, color=INK if t[0] == "lit" else "white")
            if t[0] == "match" and i == start:
                label = f"copy {t[1]} from {t[2]} back"
                width = 0.2 * len(label)  # in cells, roughly, at this font size
                lx = min(x + 0.1, per_row * cw - width)
                row = i // per_row
                line = 0 if label_end.get((row, 0), -1) < lx else 1
                label_end[(row, line)] = lx + width + 0.3
                ax.text(lx, y - 0.62 - 0.42 * line, label, ha="left", va="top", fontsize=7.2, color=INK2)
            i += m
    nlit = sum(t[0] == "lit" for t in toks)
    ax.set_xlim(-0.2, per_row * cw + 0.2)
    ax.set_ylim(-(rows - 1) * rh - 1.4, 0.8)
    ax.axis("off")
    ax.set_title(f"LZ77 at level 9: {len(TEXT)} bytes become {nlit} literals (grey) and {len(toks) - nlit} copies "
                 f"(blue), {len(z)} bytes in all", loc="left")
    save(fig, "lz77.png")


def huffman():
    """Code length against symbol frequency in one dynamic block."""
    data = (ROOT / "corpus" / "source.zig").read_bytes()[:400_000]
    out, blocks = tokens.parse(zdeflate(["-f", "raw", "-6"], data))
    assert out == data
    block = next(b for b in blocks if b["type"] == "dynamic")
    freq = collections.Counter()
    for t in block["tokens"]:
        if t[0] == "lit":
            freq[t[1]] += 1
        else:
            freq[257 + next(i for i in range(28, -1, -1) if tokens.LENGTH_BASE[i] <= t[1])] += 1
    freq[256] += 1
    total = sum(freq.values())
    lengths = block["lit_lengths"]
    fig, ax = plt.subplots(figsize=(8.5, 4.6))
    ps = [10 ** (k / 10) for k in range(-50, 1)]
    ax.plot(ps, [-math.log2(p) for p in ps], color=MUTED, linewidth=1.2, label="ideal length, −log₂ p")
    for group, color, label in ((range(256), BLUE, "literal bytes"), (range(257, 286), ORANGE, "match lengths")):
        pts = [(freq[s] / total, lengths[s]) for s in group if freq[s]]
        ax.scatter([p for p, _ in pts], [n for _, n in pts], s=22, color=color, edgecolor=SURFACE, linewidth=0.6,
                   label=label, zorder=3)
    ax.axhline(15, color=AXIS, linestyle="--", linewidth=1)
    ax.text(2.2e-5, 15.25, "DEFLATE's limit: 15 bits", color=MUTED, fontsize=8.5)
    for s, name in ((32, "space"), (10, "newline"), (257, "length 3")):
        if freq[s]:
            ax.annotate(name, (freq[s] / total, lengths[s]), xytext=(7, 6), textcoords="offset points", fontsize=8.5,
                        color=INK2, bbox=dict(boxstyle="round,pad=0.15", facecolor=SURFACE, edgecolor="none"))
    ax.set_xscale("log")
    ax.set_xlabel("share of the block's symbols, p")
    ax.set_ylabel("code length (bits)")
    ax.set_ylim(0, 16.5)
    ax.set_title(f"Huffman coding: frequent symbols get short codes ({len(block['tokens']):,} tokens of Zig source)",
                 loc="left")
    ax.legend(loc="lower left", fontsize=8.5)
    save(fig, "huffman.png")


def results():
    rows = list(csv.DictReader(open(ROOT / "docs" / "data" / "bench.csv")))
    impls = list(dict.fromkeys(r["impl"] for r in rows))
    colors = dict(zip(impls, (BLUE, ORANGE, AQUA)))
    files = ["source.zig", "server.log", "zig.bin", "signal.f64", "random.bin"]

    def get(impl, f, level, key):
        return next(float(r[key]) for r in rows if r["impl"] == impl and r["file"] == f and int(r["level"]) == level)

    fig, axes = plt.subplots(1, 3, figsize=(14, 4.2), gridspec_kw={"width_ratios": [1.25, 0.8, 1]})
    width = 0.26
    a = axes[0]
    for k, impl in enumerate(impls):
        xs = [i + (k - 1) * width for i in range(len(files))]
        a.bar(xs, [100 * get(impl, f, 6, "out_bytes") / get(impl, f, 6, "in_bytes") for f in files],
              width=width - 0.03, color=colors[impl], label=impl)
    a.set_xticks(range(len(files)), files)
    a.set_ylabel("compressed size, % of original")
    a.set_title("Size at level 6", loc="left")
    a.legend(fontsize=8.5, loc="upper left")
    a.grid(axis="x", visible=False)

    b = axes[1]
    for k, impl in enumerate(impls):
        xs = [i + (k - 1) * width for i in range(3)]
        ys = [get(impl, "source.zig", lv, "compress_mb_s") for lv in (1, 6, 9)]
        b.bar(xs, ys, width=width - 0.03, color=colors[impl])
        for x, y in zip(xs, ys):
            b.text(x, y + 3, f"{y:.0f}", ha="center", fontsize=7.5, color=INK2)
    b.set_xticks(range(3), ["level 1", "level 6", "level 9"])
    b.set_ylabel("MB/s")
    b.set_title("Compression, source.zig", loc="left")
    b.grid(axis="x", visible=False)

    c = axes[2]
    some = files[:4]
    for k, impl in enumerate(impls):
        xs = [i + (k - 1) * width for i in range(len(some))]
        c.bar(xs, [get(impl, f, 6, "decompress_mb_s") for f in some], width=width - 0.03, color=colors[impl])
    c.set_xticks(range(len(some)), some)
    c.set_ylabel("MB/s of output")
    c.set_title("Decompression, level-6 streams", loc="left")
    c.grid(axis="x", visible=False)
    fig.tight_layout()
    save(fig, "results.png")


if __name__ == "__main__":
    BIN = build.tools("ReleaseSafe")
    lz77()
    huffman()
    results()
