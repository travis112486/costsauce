# tests/test_harness.py
from tests import conftest
from tests.conftest import apply_migrations
import api


def test_dotted_imports_resolve_the_way_downstream_tasks_need():
    """Every task after this one imports via `from tests.conftest import
    apply_migrations` and (from Task 3 on) `from api.db import ...`. Both
    require the repo root on sys.path -- which the test below never exercises,
    since it consumes `raw_conn` as an auto-discovered pytest fixture and needs
    no import at all. Without `pythonpath = ["."]` in pyproject.toml's
    `[tool.pytest.ini_options]`, this fails at collection time with
    `ModuleNotFoundError: No module named 'tests'` / `'api'`, and every one of
    the 13 remaining Phase 1a tasks fails the same way.
    """
    assert callable(apply_migrations)
    assert api is not None


def test_container_reaper_registers_atexit_and_sigterm_cleanup(monkeypatch):
    """The db_url fixture's disposable container is only killed by its own
    normal pytest teardown. `_install_container_reaper` is defence in depth
    for the case where that teardown never runs (SIGINT, SIGTERM from a CI
    timeout, an uncaught exception elsewhere in session setup). This verifies
    the reaper actually wires up atexit + SIGTERM, and that `uninstall()`
    cleanly reverses both, without sending a real SIGTERM to this process
    (invoking the SIGTERM handler itself would kill the test run).
    """
    calls = []
    monkeypatch.setattr(
        conftest.subprocess, "run", lambda cmd, **kw: calls.append(cmd)
    )

    registered, unregistered = [], []
    monkeypatch.setattr(conftest.atexit, "register", registered.append)
    monkeypatch.setattr(conftest.atexit, "unregister", unregistered.append)

    prior_sigterm = conftest.signal.getsignal(conftest.signal.SIGTERM)
    cleanup, uninstall = conftest._install_container_reaper("fake-container")
    try:
        assert cleanup in registered, "cleanup must be registered with atexit"
        assert (
            conftest.signal.getsignal(conftest.signal.SIGTERM) is not prior_sigterm
        ), "a SIGTERM handler must be installed (Python has no default one)"

        cleanup()
        assert ["docker", "kill", "fake-container"] in calls
    finally:
        uninstall()

    assert cleanup in unregistered
    assert conftest.signal.getsignal(conftest.signal.SIGTERM) is prior_sigterm


async def test_postgres_is_reachable_and_is_v17(raw_conn):
    cur = await raw_conn.execute("SHOW server_version_num")
    (version_num,) = await cur.fetchone()
    assert int(version_num) >= 170000, f"need Postgres 17+, got {version_num}"
