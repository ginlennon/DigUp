"""The running DigUp desktop app, for the integrations: ask it to add a folder, and how its indexing goes.

The app owns the settings, so a folder is added by asking it (the integrations only read the index). On Linux it
answers on the session bus, under "com.abdurrahim.DigUp.Tools" (the shell's tools.rs):

    AddFolder(folder: s, tool: s, max_files: u) → s    a JSON object: {"ok": true, "added": …, "message": …} or
                                                         {"ok": false, "message": why not}
    Status() → s                                         {"ok": true, "state": "indexing|idle|paused|…", "done": n,
                                                          "total": n, "pending": [folders not indexed through yet]}

The session bus is the user's own (nothing over the network). When the app isn't running there's no one to ask:
`AppNotRunning`, and the integration says so.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

from digup_client import DigUpError

APP_ID = "com.abdurrahim.DigUp"
BUS_NAME = f"{APP_ID}.Tools"
OBJECT_PATH = "/com/abdurrahim/DigUp/Tools"
INTERFACE = "com.abdurrahim.DigUp.Tools"

NOT_RUNNING = ("DigUp isn't running, so nothing can be added: start DigUp (it adds the folder and shows it), then "
               "ask again")


class AppNotRunning(DigUpError):
    """The desktop app isn't running (or there's no session bus): no one to ask (HTTP 503)."""


class DesktopApp:
    """The desktop app over the session bus; each call opens its own short connection (thread-safe)."""

    def __init__(self, timeout: float = 30.0):
        self.timeout = timeout

    def add_folder(self, folder: str, tool: str, max_files: int) -> dict[str, Any]:
        """Asks the app to add `folder` (absolute) for `tool`, with at most `max_files` files. Its answer."""
        return self._call("AddFolder", "ssu", (folder, tool, max(0, min(int(max_files), 2**32 - 1))))

    def status(self) -> dict[str, Any] | None:
        """How the app's indexing goes; None when it isn't running."""
        try:
            return self._call("Status", None, (), timeout=3.0)
        except AppNotRunning:
            return None

    def _call(self, method: str, signature: str | None, body: tuple, timeout: float | None = None) -> dict[str, Any]:
        if not sys.platform.startswith("linux"):
            raise AppNotRunning("adding folders through the DigUp app works on Linux only (the session bus)")
        try:
            from jeepney import DBusAddress, new_method_call
            from jeepney.io.blocking import open_dbus_connection
            from jeepney.wrappers import DBusErrorResponse, unwrap_msg
        except ImportError:
            raise AppNotRunning("jeepney isn't installed (uv sync in integrations/)") from None
        address = DBusAddress(OBJECT_PATH, bus_name=BUS_NAME, interface=INTERFACE)
        try:
            connection = open_dbus_connection(bus=session_bus())
        except (OSError, KeyError, ValueError) as error:
            raise AppNotRunning(f"{NOT_RUNNING} (no session bus: {error})") from None
        try:
            reply = connection.send_and_get_reply(new_method_call(address, method, signature, body),
                                                  timeout=timeout or self.timeout)
            text = unwrap_msg(reply)[0]
        except DBusErrorResponse as error:
            if error.name in ("org.freedesktop.DBus.Error.ServiceUnknown", "org.freedesktop.DBus.Error.NameHasNoOwner"):
                raise AppNotRunning(NOT_RUNNING) from None
            raise DigUpError(f"DigUp's app answered with an error: {error}") from None
        except TimeoutError:
            raise DigUpError("DigUp's app didn't answer in time") from None
        finally:
            connection.close()
        try:
            value = json.loads(text)
        except (TypeError, ValueError):
            raise DigUpError(f"DigUp's app gave an answer that isn't JSON: {text!r}") from None
        if not isinstance(value, dict):
            raise DigUpError("DigUp's app gave an answer that isn't an object")
        return value


def session_bus() -> str:
    """The session bus's address: $DBUS_SESSION_BUS_ADDRESS, else the usual socket in $XDG_RUNTIME_DIR, else in
    /run/user/<uid> (MCP clients often start a server with a few variables only: HOME, PATH, USER …)."""
    if os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        return "SESSION"
    for runtime in (os.environ.get("XDG_RUNTIME_DIR"), f"/run/user/{os.getuid()}"):
        if runtime and os.path.exists(os.path.join(runtime, "bus")):
            return f"unix:path={os.path.join(runtime, 'bus')}"
    raise KeyError("DBUS_SESSION_BUS_ADDRESS isn't set")
