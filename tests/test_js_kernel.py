"""Runs the JS kernel's vector suite via `node --test` so `pytest` remains
the single local gate. FAILS (not skips) when node is missing: a silent skip
is silent loss of one of the three kernel implementations' coverage.

Note: `node --test tests/js/` (a bare directory positional argument) does
NOT recursively discover test files on the Node versions available in this
environment (verified against both Node v22 and v25) — only explicit glob
patterns do, per Node's own test-runner docs ("one or more glob patterns can
be provided as the final argument(s)"). So this invokes node with an
explicit glob instead of the bare directory path.
"""
import shutil
import subprocess
import pathlib

ROOT = pathlib.Path(__file__).parent.parent


def test_js_kernel_passes_golden_vectors():
    assert shutil.which("node"), (
        "node is required to verify shared/kernel.js against the golden "
        "vectors — install Node 18+ (the JS kernel is a first-class "
        "implementation, not an optional extra)")
    proc = subprocess.run(
        ["node", "--test", "tests/js/**/*.test.mjs"], cwd=ROOT,
        capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, f"node --test failed:\n{proc.stdout}\n{proc.stderr}"
