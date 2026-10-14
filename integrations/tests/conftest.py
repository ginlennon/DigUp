import os
import stat
import sys
from pathlib import Path

import pytest

FAKE = Path(__file__).with_name("fake_helper.py")


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
    for name in ("DIGUP_ROOTS", "DIGUP_CODE_ROOTS", "DIGUP_INDEX", "FAKE_SIMILAR", "FAKE_NO_READY", "FAKE_FOLDERS"):
        monkeypatch.delenv(name, raising=False)
    return state
