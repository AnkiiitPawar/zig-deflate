"""Builds the command-line tools with a given optimization mode, into
zig-out/<mode>/bin, using `zig` from PATH or the ziglang Python package."""

import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def zig():
    return ["zig"] if shutil.which("zig") else ["python3", "-m", "ziglang"]


def tools(mode):
    """mode: ReleaseFast for timing, ReleaseSafe (bounds-checked) for testing."""
    prefix = ROOT / "zig-out" / mode.lower()
    subprocess.run(zig() + ["build", f"-Doptimize={mode}", "--prefix", str(prefix)], cwd=ROOT, check=True)
    return prefix / "bin"
