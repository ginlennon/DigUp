"""A stand-in for the DigUp desktop app's tools interface (the shell's tools.rs) on a private session bus.

AddFolder(folder, tool, max_files): refuses a folder named "huge" (over the cap) and anything outside FAKE_HOME;
otherwise adds it to the settings file FAKE_SETTINGS (a folder with .git to codeFolders, as the shell does) and keeps
it pending. Status(): {"state": "indexing", "done": 1, "total": 3, "pending": [...]} until FAKE_STATE/done exists.
Every request is written to FAKE_STATE/requests.jsonl.
"""

import json
import os
import sys
from pathlib import Path

from jeepney import HeaderFields, MessageType, new_error, new_method_return
from jeepney.bus_messages import message_bus
from jeepney.io.blocking import open_dbus_connection

NAME = "com.abdurrahim.DigUp.Tools"
STATE = Path(os.environ["FAKE_STATE"])
SETTINGS = Path(os.environ["FAKE_SETTINGS"])
HOME = os.environ["FAKE_HOME"]
pending: list[str] = []


def add(folder: str, tool: str, max_files: int) -> dict:
    with open(STATE / "requests.jsonl", "a") as log:
        log.write(json.dumps({"folder": folder, "tool": tool, "max_files": max_files}) + "\n")
    if not folder.startswith(HOME + "/"):
        return {"ok": False, "message": f"{folder} isn't in your home folder: tools may only add folders inside it."}
    if os.path.basename(folder) == "huge":
        return {"ok": False, "message": f"{folder} has more than {max_files} files"}
    settings = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    key = "codeFolders" if os.path.isdir(os.path.join(folder, ".git")) else "folders"
    settings.setdefault(key, [])
    if folder not in settings[key]:
        settings[key].append(folder)
    SETTINGS.write_text(json.dumps(settings))
    pending.append(folder)
    return {"ok": True, "added": True, "path": folder, "code": key == "codeFolders", "files": 3, "skipped": [],
            "indexing": "started", "message": f"{tool} added {folder} to DigUp"}


def status() -> dict:
    if (STATE / "done").exists():
        pending.clear()
        return {"ok": True, "state": "idle", "done": 3, "total": 3, "pending": []}
    return {"ok": True, "state": "indexing", "done": 1, "total": 3, "pending": list(pending)}


def main():
    connection = open_dbus_connection(bus="SESSION")
    reply = connection.send_and_get_reply(message_bus.RequestName(NAME))
    if reply.body[0] != 1:
        sys.exit("the name is taken")
    (STATE / "app-ready").write_text("1")
    while True:
        message = connection.receive()
        if message.header.message_type != MessageType.method_call:
            continue
        member = message.header.fields.get(HeaderFields.member)
        if member == "AddFolder":
            answer = add(*message.body)
        elif member == "Status":
            answer = status()
        else:
            connection.send(new_error(message, "org.freedesktop.DBus.Error.UnknownMethod"))
            continue
        connection.send(new_method_return(message, "s", (json.dumps(answer),)))


if __name__ == "__main__":
    main()
