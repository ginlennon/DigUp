import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

FAKE = Path(__file__).with_name("fake_helper.py")
FAKE_APP = Path(__file__).with_name("fake_app.py")


@pytest.fixture
def fake_helper(tmp_path, monkeypatch):
    """An executable that runs the fake helper, as DIGUP_HELPER; its state folder is FAKE_STATE."""
    state = tmp_path / "state"
    state.mkdir()
    wrapper = tmp_path / "digup"
    wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE}" "$@"\n')
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("DIGUP_HELPER", str(wrapper))
    monkeypatch.setenv("FAKE_STATE", str(state))
    monkeypatch.setenv("FAKE_ROOT", "/data")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))   # never the real app's settings
    # Never the real session bus (the user's DigUp is on it): a bus that isn't there, so "DigUp isn't running".
    monkeypatch.setenv("DBUS_SESSION_BUS_ADDRESS", f"unix:path={tmp_path / 'no-bus'}")
    for name in ("DIGUP_ROOTS", "DIGUP_CODE_ROOTS", "DIGUP_INDEX", "DIGUP_SCOPE", "FAKE_SIMILAR", "FAKE_NO_READY",
                 "FAKE_FOLDERS"):
        monkeypatch.delenv(name, raising=False)
    return state


@pytest.fixture
def fake_app(fake_helper, tmp_path, monkeypatch):
    """A private session bus (its own dbus-daemon) with the stand-in for the desktop app on it (fake_app.py); the
    tests' DBUS_SESSION_BUS_ADDRESS points at it. Yields the settings file the stand-in writes."""
    if shutil.which("dbus-daemon") is None:
        pytest.skip("needs dbus-daemon")
    socket = tmp_path / "bus"
    daemon = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--nopidfile", f"--address=unix:path={socket}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if socket.exists():
            break
        time.sleep(0.05)
    settings = tmp_path / "config" / "com.abdurrahim.DigUp" / "settings.json"
    settings.parent.mkdir(parents=True)
    monkeypatch.setenv("DBUS_SESSION_BUS_ADDRESS", f"unix:path={socket}")
    monkeypatch.setenv("FAKE_SETTINGS", str(settings))
    monkeypatch.setenv("FAKE_HOME", str(tmp_path / "home"))
    app = subprocess.Popen([sys.executable, str(FAKE_APP)], env=dict(os.environ))
    for _ in range(100):
        if (fake_helper / "app-ready").exists():
            break
        time.sleep(0.05)
    try:
        yield settings
    finally:
        for process in (app, daemon):
            process.terminate()
            process.wait(timeout=5)
