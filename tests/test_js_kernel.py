"""Runs the JS kernel's vector suite via `node --test` so `pytest` remains
the single local gate. Guards against two silent-coverage-loss modes:
1. FAILS (not skips) when node is missing.
2. FAILS (not a false PASSED) when no *.test.mjs files are found under
   tests/js/ — a bare `node --test <glob-that-matches-nothing>` exits 0
   with "0 tests, 0 pass", so if kernel.test.mjs were ever renamed, moved,
   or typo'd out of reach, the wrapper would silently report success while
   running zero golden vectors. We resolve the file list in Python, assert
   it's non-empty, and pass explicit files to node instead of a glob.

Note: `node --test tests/js/` (a bare directory positional argument) does
NOT recursively discover test files on the Node versions available in this
environment (verified against both Node v22 and v25) — only explicit file
or glob arguments do, per Node's own test-runner docs. Hence the explicit
file list below rather than the brief's bare directory path.
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
    files = sorted(str(p) for p in (ROOT / "tests" / "js").rglob("*.test.mjs"))
    assert files, (
        "no JS test files found under tests/js/ — coverage would be "
        "silently skipped")
    proc = subprocess.run(
        ["node", "--test", *files], cwd=ROOT,
        capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, f"node --test failed:\n{proc.stdout}\n{proc.stderr}"
