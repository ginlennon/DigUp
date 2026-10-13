// DigUp's settings window: the folders and what's skipped in them, pausing indexing and the GPU switch, the shortcut
// (on GNOME a GNOME shortcut, which this window can write), starting at login, and where DigUp keeps things. Each
// change applies at once, as in the Mac app's Settings; the shell saves it and the helpers follow (search-service is
// told the folders, the watcher and indexing start over with them).
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const isWindows = /Win/.test(navigator.platform);

const $ = (id) => document.getElementById(id);
let info = null;
let home = "";

async function load() {
  try {
    info = await invoke("settings_info");
  } catch (error) {
    problem(error);
    return;
  }
  render();
}

function render() {
  renderFolders();
  renderSkipped();
  // Not while it's being typed in.
  if (document.activeElement !== $("types")) $("types").value = info.skipTypes.join(", ");
  $("from-launch").hidden = !info.foldersFromLaunch;

  $("pause").textContent = info.paused ? "Resume Indexing" : "Pause Indexing";
  $("pause-title").textContent = info.paused ? "Indexing is paused" : "Indexing";
  showStatus(info.status);
  $("gpu").checked = info.gpu;

  renderShortcut();
  $("login").checked = info.startsAtLogin;

  $("version").textContent = `DigUp ${info.version}`;
  for (const name of ["index", "models", "logs", "settings"]) {
    $(`path-${name}`).textContent = info.paths[name] ? shown(info.paths[name]) : "the helper's default";
    $(`path-${name}`).title = info.paths[name] || "";
  }
}

function showStatus(text) {
  $("status").textContent = info.paused
    ? "Nothing is indexed until you resume, also after a restart. Search works as before."
    : text || "";
}

// MARK: Folders

function renderFolders() {
  const list = $("folders");
  list.replaceChildren();
  if (!info.folders.length) list.append(emptyRow("No folders yet. Add the ones DigUp should search."));
  for (const path of info.folders) {
    list.append(folderRow(path, "Remove", "Its files leave the index; adding it back reads them again.", () =>
      save({ folders: info.folders.filter((folder) => folder !== path) })));
  }
}

function renderSkipped() {
  const list = $("skipped");
  list.replaceChildren();
  if (!info.skipped.length) list.append(emptyRow("None. Caches, app folders and hidden folders are skipped anyway."));
  for (const path of info.skipped) {
    list.append(folderRow(path, "Search Again", null, () =>
      save({ skipped: info.skipped.filter((folder) => folder !== path) })));
  }
}

/// A folder with a button that removes it; `warning` makes the button ask once more first ("Remove?").
function folderRow(path, title, warning, remove) {
  const row = element("div", "row folder");
  const text = element("div", "text");
  text.append(element("div", "name", path.split(/[\\/]/).filter(Boolean).pop() || path),
              element("div", "path", shown(path)));
  const button = element("button", "remove", title);
  button.onclick = () => {
    if (warning && !button.classList.contains("confirm")) {
      button.classList.add("confirm");
      button.textContent = `${title}?`;
      button.title = warning;
      setTimeout(() => {
        button.classList.remove("confirm");
        button.textContent = title;
      }, 4000);
      return;
    }
    remove();
  };
  row.append(text, button);
  return row;
}

function emptyRow(text) {
  return element("div", "row empty", text);
}

$("add-folders").addEventListener("click", async () => {
  const picked = (await invoke("pick_folders")).filter((path) => !info.folders.includes(path));
  if (picked.length) save({ folders: [...info.folders, ...picked] });
});

$("add-skipped").addEventListener("click", async () => {
  const picked = (await invoke("pick_folders", { title: "Skip Folders" })).filter((path) => !info.skipped.includes(path));
  if (picked.length) save({ skipped: [...info.skipped, ...picked] });
});

$("types").addEventListener("change", () => save({ skipTypes: $("types").value }));
$("types").addEventListener("keydown", (event) => {
  if (event.key === "Enter") $("types").blur();
});

/// Saves the folders, the skipped folders and the skipped types, one of them changed.
async function save(change) {
  const next = {
    folders: change.folders ?? info.folders,
    skipped: change.skipped ?? info.skipped,
    skipTypes: change.skipTypes ?? info.skipTypes.join(", "),
  };
  try {
    await invoke("save_folders", next);
    problem(null);
  } catch (error) {
    problem(error);
  }
  load();
}

// MARK: Indexing, the shortcut, login

$("pause").addEventListener("click", () => run("set_paused", { paused: !info.paused }, $("pause")));
$("gpu").addEventListener("change", () => run("set_gpu", { gpu: $("gpu").checked }, $("gpu")));
$("login").addEventListener("change", () => run("set_starts_at_login", { on: $("login").checked }, $("login")));
$("set-up-shortcut").addEventListener("click", () => run("set_up_shortcut", {}, $("set-up-shortcut")));

/// A command, with its control disabled until it's done (stopping a helper takes a moment).
async function run(command, args, control) {
  control.disabled = true;
  try {
    await invoke(command, args);
    problem(null);
  } catch (error) {
    problem(error);
  }
  control.disabled = false;
  load();
}

function renderShortcut() {
  $("keys").replaceChildren(...info.hotkey.split("+").filter(Boolean).map((key) => element("span", "key", key)));
  const shortcut = info.shortcut;
  $("gnome").hidden = !info.gnome;
  if (!info.gnome) {
    $("shortcut-text").textContent = "DigUp listens for it while it runs.";
    return;
  }
  // Wayland lets no app watch the keyboard, so on GNOME the shortcut is one of GNOME's own.
  $("shortcut-text").textContent = "On GNOME it's a keyboard shortcut of GNOME's that opens DigUp's panel.";
  if (!shortcut) {
    $("gnome-title").textContent = "GNOME's settings can't be read";
    $("gnome-text").textContent = "Add it in Settings › Keyboard › Custom Shortcuts, running: " + info.shortcutCommand;
    $("set-up-shortcut").hidden = true;
    return;
  }
  $("set-up-shortcut").hidden = false;
  const current = shortcut.installed && shortcut.keys === info.hotkey && shortcut.command === info.shortcutCommand;
  if (current) {
    $("gnome-title").textContent = "Set up in GNOME";
    $("gnome-text").textContent = "Change the keys in Settings › Keyboard › Custom Shortcuts (“DigUp search”).";
    $("set-up-shortcut").textContent = "Set Up Again";
  } else if (shortcut.installed) {
    $("gnome-title").textContent = "GNOME's shortcut is different";
    $("gnome-text").textContent = `It's ${shortcut.keys || "no keys"}, running ${shortcut.command}. Set it up for `
      + `${info.hotkey} and this DigUp.`;
    $("set-up-shortcut").textContent = "Set Up the Shortcut";
  } else {
    $("gnome-title").textContent = "Not set up yet";
    $("gnome-text").textContent = `Adds ${info.hotkey} to GNOME's custom shortcuts (your other shortcuts stay).`;
    $("set-up-shortcut").textContent = "Set Up the Shortcut";
  }
}

// MARK: Helpers

/// "~/Pictures" for a folder in the home folder.
function shown(path) {
  const short = home && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
  return isWindows ? short.replaceAll("/", "\\") : short;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function problem(error) {
  $("problem").hidden = !error;
  $("problem").textContent = error ? String(error) : "";
}

tauri.event.listen("settings-changed", load);
tauri.event.listen("status", ({ payload }) => {
  if (info) {
    info.status = payload;
    showStatus(payload);
  }
});

tauri.path.homeDir()
  .then((folder) => { home = folder.replace(/[\\/]$/, ""); })
  .catch(() => {})
  .finally(load);
