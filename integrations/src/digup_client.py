"""A client for DigUp's search helper, `digup search-service`.

The helper keeps the index open and the query encoder warm, and speaks JSON lines: one request per line on stdin,
one reply per line on stdout carrying the request's `id`; lines without an `id` are events (`{"event":"ready",…}`
first, then e.g. `{"event":"encoder","state":"ready",…}`). This module starts it, waits for it to be ready, matches
replies to requests from any number of threads, starts it again (once per request) when it died, and shuts it down.

Where the helper comes from (`find_helper`): `--helper`, else `$DIGUP_HELPER`, else `digup` on PATH, else a dev build
in the repo this file is in (`<repo>/.build/release/digup`). A dev build needs the llama.cpp backends, so
`DIGUP_BACKENDS=<repo>/Vendor/llama/lib` is set for it when it isn't set already.

What it searches (`HelperConfig.load`): the folders given, else `$DIGUP_ROOTS`, else the desktop app's settings
(`~/.config/com.abdurrahim.DigUp/settings.json`: `folders`, `skipped`, `skipTypes`). The index is the helper's default
(`~/.local/share/digup/index` on Linux) unless `--index` or `$DIGUP_INDEX` says otherwise. The helper only reads the
index (SQLite in WAL mode), so it can run beside the desktop app's own.
"""

from __future__ import annotations

import collections
import itertools
import json
import os
import shutil
import subprocess
import threading
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

__all__ = [
    "DigUpClient",
    "DigUpError",
    "HelperConfig",
    "HelperDied",
    "HelperError",
    "HelperNotFound",
    "HelperTimeout",
    "find_helper",
    "helper_env",
    "load_settings",
    "repo_root",
    "settings_path",
]


class DigUpError(Exception):
    """Anything that went wrong talking to DigUp; the message is meant for a person (or a model) to read."""


class HelperNotFound(DigUpError):
    pass


class HelperDied(DigUpError):
    pass


class HelperTimeout(DigUpError):
    pass


class HelperError(DigUpError):
    """The helper answered `{"ok": false, "error": …}`."""

    def __init__(self, op: str, message: str):
        super().__init__(f"digup {op}: {message}")
        self.op = op
        self.message = message

    @property
    def unsupported(self) -> bool:
        """The helper doesn't know this op (an older helper than the feature)."""
        return self.message.startswith("unknown op")


# MARK: Finding the helper and its settings

_THIS_REPO = Path(__file__).resolve().parents[2]   # <repo>/integrations/src/digup_client.py


def repo_root() -> Path | None:
    """The DigUp checkout this integration lives in (or `$DIGUP_REPO`), if it is one."""
    if os.environ.get("DIGUP_REPO"):
        return Path(os.environ["DIGUP_REPO"]).expanduser()
    return _THIS_REPO if (_THIS_REPO / "Package.swift").is_file() else None


def find_helper(explicit: str | os.PathLike[str] | None = None) -> Path:
    """The `digup` binary to run: `explicit`, `$DIGUP_HELPER`, `digup` on PATH, then `<repo>/.build/release/digup`."""
    for source, value in (("--helper", explicit), ("DIGUP_HELPER", os.environ.get("DIGUP_HELPER"))):
        if value:
            path = Path(value).expanduser()
            if path.is_file() and os.access(path, os.X_OK):
                return path
            raise HelperNotFound(f"{source} names {path}, which isn't an executable file")
    on_path = shutil.which("digup")
    if on_path:
        return Path(on_path)
    repo = repo_root()
    if repo is not None:
        built = repo / ".build" / "release" / "digup"
        if built.is_file() and os.access(built, os.X_OK):
            return built
    raise HelperNotFound(
        "DigUp's helper `digup` wasn't found: set DIGUP_HELPER to its path, put it on PATH, or build it in the "
        "repo (swift build -c release --product digup, see the repo's SETUP.md)")


def helper_env(helper: Path, base: dict[str, str] | None = None) -> dict[str, str]:
    """The helper's environment: ours, plus DIGUP_BACKENDS for a dev build (`<checkout>/.build/…/digup`)."""
    env = dict(os.environ if base is None else base)
    if not env.get("DIGUP_BACKENDS"):
        for parent in helper.resolve().parents:
            if parent.name == ".build":
                backends = parent.parent / "Vendor" / "llama" / "lib"
                if backends.is_dir():
                    env["DIGUP_BACKENDS"] = str(backends)
                break
    return env


def settings_path() -> Path:
    """The desktop app's settings on Linux (`$XDG_CONFIG_HOME/com.abdurrahim.DigUp/settings.json`)."""
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return Path(config) / "com.abdurrahim.DigUp" / "settings.json"


def load_settings(path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """The desktop app's settings, or {} when there are none (or they can't be read)."""
    try:
        with open(Path(path).expanduser() if path else settings_path(), encoding="utf-8") as file:
            value = json.load(file)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def absolute(folder: str) -> str:
    """`~/Documents/` → `/home/you/Documents` (no symlinks resolved: the index keeps paths as they were found)."""
    return os.path.normpath(os.path.abspath(os.path.expanduser(folder)))


def _env_list(name: str) -> list[str]:
    return [part for part in os.environ.get(name, "").split(os.pathsep) if part.strip()]


def _strings(value: Any) -> list[str]:
    return [item for item in value if isinstance(item, str) and item] if isinstance(value, list) else []


@dataclass
class HelperConfig:
    """How to start `digup search-service`: which binary, which index, which folders."""

    helper: str | None = None              # None: `find_helper`
    index: str | None = None               # None: the helper's default
    roots: list[str] = field(default_factory=list)          # searched folders ([]: all of the index)
    excludes: list[str] = field(default_factory=list)       # folders inside them that aren't
    exclude_ext: list[str] = field(default_factory=list)    # extensions left out ("heic")
    code_roots: list[str] = field(default_factory=list)     # the code index's folders (code search needs them)
    code_excludes: list[str] = field(default_factory=list)
    encoder_idle: float | None = None      # seconds before the idle encoder exits (helper default: 300)
    env: dict[str, str] = field(default_factory=dict)       # extra environment (e.g. DIGUP_GPU=0)
    settings_file: str | None = None       # where `roots` came from, when they came from the app's settings

    @classmethod
    def load(cls, *, helper: str | None = None, index: str | None = None, roots: list[str] | None = None,
             excludes: list[str] | None = None, exclude_ext: list[str] | None = None,
             code_roots: list[str] | None = None, code_excludes: list[str] | None = None,
             encoder_idle: float | None = None, settings: str | None = None,
             use_settings: bool = True) -> HelperConfig:
        """Flags first, then the environment (DIGUP_INDEX, DIGUP_ROOTS, DIGUP_CODE_ROOTS: os.pathsep-separated),
        then the desktop app's settings for whatever is still missing."""
        config = cls(helper=helper, index=index or os.environ.get("DIGUP_INDEX") or None,
                     encoder_idle=encoder_idle)
        config.roots = list(roots or []) or _env_list("DIGUP_ROOTS")
        config.excludes = list(excludes or [])
        config.exclude_ext = list(exclude_ext or [])
        config.code_roots = list(code_roots or []) or _env_list("DIGUP_CODE_ROOTS")
        config.code_excludes = list(code_excludes or [])
        if use_settings and (not config.roots or not config.code_roots):
            path = Path(settings).expanduser() if settings else settings_path()
            app = load_settings(path)
            if not config.roots and _strings(app.get("folders")):
                config.roots = _strings(app.get("folders"))
                config.excludes += _strings(app.get("skipped"))
                config.exclude_ext += _strings(app.get("skipTypes"))
                config.settings_file = str(path)
            if not config.code_roots:   # not in the Linux app's settings yet; read when a later one writes them
                config.code_roots = _strings(app.get("codeFolders"))
                config.code_excludes += _strings(app.get("codeSkipped"))
        config.roots = [absolute(folder) for folder in config.roots]
        config.excludes = [absolute(folder) for folder in config.excludes]
        config.code_roots = [absolute(folder) for folder in config.code_roots]
        config.code_excludes = [absolute(folder) for folder in config.code_excludes]
        config.exclude_ext = [ext.strip().lstrip(".").lower() for ext in config.exclude_ext if ext.strip()]
        return config

    def arguments(self) -> list[str]:
        """`search-service`'s arguments."""
        args = ["search-service"]
        if self.index:
            args += ["--index", absolute(self.index)]
        for folder in self.code_roots:
            args += ["--code-root", folder]
        for folder in self.code_excludes:
            args += ["--code-exclude", folder]
        for folder in self.excludes:
            args += ["--exclude", folder]
        for extension in self.exclude_ext:
            args += ["--exclude-ext", extension]
        if self.encoder_idle is not None:
            args += ["--encoder-idle", f"{self.encoder_idle:g}"]
        return args + self.roots

    def describe(self) -> dict[str, Any]:
        return {"helper": self.helper, "index": self.index, "roots": self.roots, "excludes": self.excludes,
                "exclude_ext": self.exclude_ext, "code_roots": self.code_roots, "settings": self.settings_file}


# MARK: The client


class _Process:
    """One run of the helper: its replies still owed, and whether it's ready or gone."""

    def __init__(self, popen: subprocess.Popen[str]):
        self.popen = popen
        self.pending: dict[int, Future[dict[str, Any]]] = {}
        self.ready: Future[dict[str, Any]] = Future()
        self.lock = threading.Lock()
        self.dead: DigUpError | None = None
        self.stderr: collections.deque[str] = collections.deque(maxlen=20)

    def fail(self, error: DigUpError) -> None:
        with self.lock:
            if self.dead is None:
                self.dead = error
            pending, self.pending = self.pending, {}
        if not self.ready.done():
            self.ready.set_exception(error)
        for future in pending.values():
            if not future.done():
                future.set_exception(error)


class DigUpClient:
    """A thread-safe client for one `digup search-service`, started on the first request.

    `request(op, **fields)` returns the reply (without its `id`), and raises `HelperError` for an error reply,
    `HelperTimeout` when no reply comes in time (the helper is then stopped, so the next request starts a fresh one),
    and `HelperDied` when it died and starting it again didn't help.
    """

    def __init__(self, config: HelperConfig | None = None, *, start_timeout: float = 60.0,
                 request_timeout: float = 60.0, on_event: Callable[[dict[str, Any]], None] | None = None):
        self.config = config or HelperConfig.load()
        self.start_timeout = start_timeout
        self.request_timeout = request_timeout
        self.on_event = on_event
        self.events: dict[str, dict[str, Any]] = {}   # the last event of each kind ("ready", "encoder")
        self.starts = 0
        self._ids = itertools.count(1)
        self._lock = threading.Lock()
        self._process: _Process | None = None
        self._closed = False

    def __enter__(self) -> DigUpClient:
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    @property
    def running(self) -> bool:
        process = self._process
        return process is not None and process.dead is None and process.popen.poll() is None

    def start(self) -> dict[str, Any]:
        """Starts the helper if it isn't running, and returns its ready event."""
        return self._running().ready.result()

    def request(self, op: str, timeout: float | None = None, **fields: Any) -> dict[str, Any]:
        """Sends `{"op": op, **fields}` and returns the reply; a helper that died is started again, once."""
        try:
            return self._attempt(op, timeout, fields)
        except HelperDied:
            if self._closed:
                raise
            return self._attempt(op, timeout, fields)

    def _attempt(self, op: str, timeout: float | None, fields: dict[str, Any]) -> dict[str, Any]:
        process = self._running()
        request_id = next(self._ids)
        future: Future[dict[str, Any]] = Future()
        with process.lock:
            dead = process.dead
            if dead is None:
                process.pending[request_id] = future
        if dead is not None:
            raise dead
        try:
            line = json.dumps({"id": request_id, "op": op, **fields}, ensure_ascii=False)
            process.popen.stdin.write(line + "\n")   # type: ignore[union-attr]
            process.popen.stdin.flush()               # type: ignore[union-attr]
        except (OSError, ValueError):
            self._died(process)
            raise process.dead or HelperDied("digup's helper stopped") from None
        seconds = self.request_timeout if timeout is None else timeout
        try:
            reply = future.result(timeout=seconds)
        except FutureTimeout:
            with process.lock:
                process.pending.pop(request_id, None)
            self._stop(process)
            raise HelperTimeout(f"digup {op}: no answer in {seconds:g} s (the helper was stopped; the next "
                                "request starts it again)") from None
        if reply.get("ok") is False and "error" in reply:
            raise HelperError(op, str(reply["error"]))
        return reply

    def close(self) -> None:
        """Asks the helper to quit, then terminates (and finally kills) it."""
        with self._lock:
            self._closed = True
            process, self._process = self._process, None
        if process is not None:
            self._stop(process, polite=True)

    # MARK: The process

    def _running(self) -> _Process:
        with self._lock:
            if self._closed:
                raise DigUpError("the DigUp client is closed")
            process = self._process
            if process is None or process.dead is not None or process.popen.poll() is not None:
                if process is not None:
                    self._stop(process)
                process = self._process = self._spawn()
        try:
            process.ready.result(timeout=self.start_timeout)
        except FutureTimeout:
            self._stop(process)
            raise HelperTimeout(f"digup's helper wasn't ready after {self.start_timeout:g} s") from None
        return process

    def _spawn(self) -> _Process:
        helper = find_helper(self.config.helper)
        env = helper_env(helper)
        env.update(self.config.env)
        try:
            popen = subprocess.Popen(
                [str(helper), *self.config.arguments()], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", bufsize=1, env=env)
        except OSError as error:
            raise HelperNotFound(f"can't start {helper}: {error}") from error
        self.starts += 1
        process = _Process(popen)
        threading.Thread(target=self._read, args=(process,), name="digup-stdout", daemon=True).start()
        threading.Thread(target=self._read_errors, args=(process,), name="digup-stderr", daemon=True).start()
        return process

    def _read(self, process: _Process) -> None:
        stdout = process.popen.stdout
        assert stdout is not None
        try:
            for line in stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue   # not ours (a library printing to stdout)
                if not isinstance(message, dict):
                    continue
                request_id = message.pop("id", None)
                if request_id is not None:
                    with process.lock:
                        future = process.pending.pop(request_id, None) if isinstance(request_id, int) else None
                    if future is not None and not future.done():
                        future.set_result(message)
                    continue
                event = message.get("event")
                if isinstance(event, str):
                    self.events[event] = message
                    if event == "ready" and not process.ready.done():
                        process.ready.set_result(message)
                    if self.on_event is not None:
                        try:
                            self.on_event(message)
                        except Exception:   # a listener's bug mustn't stop the replies
                            pass
        except (OSError, ValueError):
            pass
        self._died(process)

    def _read_errors(self, process: _Process) -> None:
        stderr = process.popen.stderr
        assert stderr is not None
        try:
            for line in stderr:
                if line.strip():
                    process.stderr.append(line.rstrip()[:500])
        except (OSError, ValueError):
            pass

    def _died(self, process: _Process) -> None:
        try:
            code = process.popen.wait(timeout=2)
        except subprocess.TimeoutExpired:
            code = None
        detail = f" (exit {code})" if code is not None else ""
        last = " | ".join(list(process.stderr)[-3:])
        process.fail(HelperDied(f"digup's helper stopped{detail}" + (f": {last}" if last else "")))

    def _stop(self, process: _Process, polite: bool = False) -> None:
        popen = process.popen
        if polite and popen.poll() is None and process.dead is None:
            try:
                popen.stdin.write(json.dumps({"id": 0, "op": "quit"}) + "\n")   # type: ignore[union-attr]
                popen.stdin.flush()                                             # type: ignore[union-attr]
                popen.wait(timeout=3)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
        if popen.poll() is None:
            popen.terminate()
            try:
                popen.wait(timeout=3)
            except subprocess.TimeoutExpired:
                popen.kill()
                popen.wait(timeout=3)
        for stream in (popen.stdin, popen.stdout, popen.stderr):
            try:
                if stream is not None:
                    stream.close()
            except OSError:
                pass
        process.fail(HelperDied("digup's helper was stopped"))
