import json
import os
import stat
import threading
from pathlib import Path

import pytest

import digup_client
from digup_client import (DigUpClient, HelperConfig, HelperDied, HelperError, HelperNotFound, HelperTimeout,
                          find_helper, helper_env)


def client(**kwargs):
    return DigUpClient(HelperConfig.load(roots=["/data"]), **kwargs)


def test_ready_search_and_quit(fake_helper):
    with client() as digup:
        assert digup.start()["index"] == "/idx"
        reply = digup.request("search", q="zebra", limit=2)
        assert [hit["segment_id"] for hit in reply["hits"]] == [272, 31]
        assert "id" not in reply
        assert digup.request("text", segment=31)["text"].startswith("Page three")
    assert (fake_helper / "quit").exists()


def test_arguments_reach_the_helper(fake_helper):
    config = HelperConfig.load(roots=["~/Pics"], excludes=["~/Pics/old"], exclude_ext=[".HEIC"],
                               code_roots=["/src"], index="/idx", encoder_idle=30)
    with DigUpClient(config) as digup:
        digup.start()
    argv = json.loads((fake_helper / "argv.json").read_text())["argv"]
    home = os.path.expanduser("~")
    assert argv == ["search-service", "--index", "/idx", "--code-root", "/src", "--exclude", f"{home}/Pics/old",
                    "--exclude-ext", "heic", "--encoder-idle", "30", f"{home}/Pics"]


def test_concurrent_requests_get_their_own_replies(fake_helper):
    with client() as digup:
        results = {}

        def ask(n):
            results[n] = digup.request("text", segment=[31, 12, 77, 5][n % 4])["text"]

        threads = [threading.Thread(target=ask, args=(n,)) for n in range(40)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    for n, text in results.items():
        expected = {0: "Page three", 1: "buy milk", 2: "import random", 3: None}[n % 4]
        assert text == expected or (text or "").startswith(expected)


def test_events_are_kept(fake_helper):
    seen = []
    with client(on_event=seen.append) as digup:
        digup.request("search", q="event")
    assert digup.events["encoder"]["state"] == "ready"
    assert {"event": "encoder", "state": "ready"} in seen


def test_error_reply_and_unknown_op(fake_helper):
    with client() as digup:
        with pytest.raises(HelperError, match="something broke") as error:
            digup.request("search", q="error")
        assert not error.value.unsupported
        with pytest.raises(HelperError) as error:
            digup.request("similar", path="/x")
        assert error.value.unsupported
        assert digup.request("status")["encoder"] == "stopped"   # still running after errors


def test_a_dead_helper_is_started_again_once(fake_helper):
    with client() as digup:
        reply = digup.request("search", q="die")     # dies the first time, answers the second
        assert len(reply["hits"]) == 4
        assert digup.starts == 2
        with pytest.raises(HelperDied, match="exit 4"):
            digup.request("search", q="dieever")
        assert digup.request("status")["vectors"] == 0   # and recovers for the next request


def test_timeout_stops_the_helper_and_the_next_request_restarts_it(fake_helper):
    with client(request_timeout=0.5) as digup:
        with pytest.raises(HelperTimeout, match="no answer"):
            digup.request("search", q="hang")
        assert digup.request("status")["encoder"] == "stopped"
        assert digup.starts == 2


def test_start_timeout(fake_helper, monkeypatch):
    monkeypatch.setenv("FAKE_NO_READY", "1")
    with client(start_timeout=0.5) as digup:
        with pytest.raises(HelperTimeout, match="ready"):
            digup.request("status")


def test_closed_client_refuses(fake_helper):
    digup = client()
    digup.request("status")
    digup.close()
    assert not digup.running
    with pytest.raises(digup_client.DigUpError, match="closed"):
        digup.request("status")


# MARK: Finding the helper


def _executable(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def test_find_helper_order(tmp_path, monkeypatch):
    explicit = _executable(tmp_path / "a" / "digup")
    from_env = _executable(tmp_path / "b" / "digup")
    on_path = _executable(tmp_path / "c" / "digup")
    repo = tmp_path / "repo"
    built = _executable(repo / ".build" / "release" / "digup")
    monkeypatch.setenv("DIGUP_REPO", str(repo))
    monkeypatch.setenv("DIGUP_HELPER", str(from_env))
    monkeypatch.setenv("PATH", str(on_path.parent))
    assert find_helper(explicit) == explicit
    assert find_helper() == from_env
    monkeypatch.delenv("DIGUP_HELPER")
    assert find_helper() == on_path
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    assert find_helper() == built
    built.unlink()
    with pytest.raises(HelperNotFound, match="DIGUP_HELPER"):
        find_helper()
    monkeypatch.setenv("DIGUP_HELPER", str(tmp_path / "missing"))
    with pytest.raises(HelperNotFound, match="isn't an executable"):
        find_helper()


def test_dev_build_gets_its_backends(tmp_path):
    built = _executable(tmp_path / "repo" / ".build" / "release" / "digup")
    (tmp_path / "repo" / "Vendor" / "llama" / "lib").mkdir(parents=True)
    env = helper_env(built, base={})
    assert env["DIGUP_BACKENDS"] == str((tmp_path / "repo" / "Vendor" / "llama" / "lib").resolve())
    assert helper_env(built, base={"DIGUP_BACKENDS": "/mine"})["DIGUP_BACKENDS"] == "/mine"
    assert "DIGUP_BACKENDS" not in helper_env(_executable(tmp_path / "bin" / "digup"), base={})


def test_settings_give_roots_when_none_are_given(tmp_path, monkeypatch):
    for name in ("DIGUP_ROOTS", "DIGUP_CODE_ROOTS", "DIGUP_INDEX"):
        monkeypatch.delenv(name, raising=False)
    settings = tmp_path / "config" / "com.abdurrahim.DigUp" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({"folders": ["/home/me/Docs", "/home/me/Pics"], "skipped": ["/home/me/Docs/old"],
                                    "skipTypes": ["heic"], "hotkey": ""}))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    config = HelperConfig.load()
    assert config.roots == ["/home/me/Docs", "/home/me/Pics"]
    assert config.excludes == ["/home/me/Docs/old"] and config.exclude_ext == ["heic"]
    assert config.settings_file == str(settings)
    given = HelperConfig.load(roots=["/x"])
    assert given.roots == ["/x"] and given.excludes == [] and given.settings_file is None
    monkeypatch.setenv("DIGUP_ROOTS", os.pathsep.join(["/r1", "/r2"]))
    assert HelperConfig.load().roots == ["/r1", "/r2"]
    settings.write_text("not json")
    monkeypatch.delenv("DIGUP_ROOTS")
    assert HelperConfig.load().roots == []
