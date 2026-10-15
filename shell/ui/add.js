// The window that adds a folder on the spot (PLANS/FOLDERS_PLAN.md, A3; the shell's adding.rs). It says what DigUp
// makes of the folder: one it won't take, one it searches already (it only becomes the panel's scope, and skipped
// folders in it can be taken in), a git repo (code search), or a new folder. For one to index, its folders are a
// checkbox tree with what's in each and about how long its first pass takes (`digup estimate`); unchecked ones are
// skipped. Start puts it into the settings, where it stays like any folder (Settings takes it out again); its files
// are indexed first, and the panel opens searching in it.
//
// Keys: ↑ ↓ move between the folders, → shows the folders inside one, ← hides them (or goes back up to the folder
// they're in), Space checks or unchecks, ↩ starts, Esc cancels.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const isWindows = /Win/.test(navigator.platform);
/// Folders left out unless checked: what tools build, install or cache. (The crawler never reads hidden folders and
/// node_modules or venv anyway; these are for the ones that show up.)
const LEFT_OUT = new Set(["node_modules", "venv", ".venv", "target", "build", "dist", ".git", "__pycache__", "cache",
                          "caches", ".cache", ".tox", ".gradle"]);
/// More files than this: the note says the first pass takes a while.
const MANY = 20000;
const CHEVRON = '<svg viewBox="0 0 16 16"><path d="M6 3.5 L10.5 8 L6 12.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const $ = (id) => document.getElementById(id);
let look = null;        // what DigUp makes of the folder (adding.rs's Look)
let paused = false;
let whole = null;       // the estimate for the whole folder (new folders and repos)
let nodes = new Map();  // path → {answer, checked, open, children (paths, once counted), parent, level, row}
let shown = 0;          // which folder this window shows (a new one may come while it counts)
let home = "";

async function start() {
  const showing = ++shown;
  nodes = new Map();
  whole = null;
  $("tree").replaceChildren();
  $("note").hidden = true;
  $("documents-option").hidden = true;
  $("start").hidden = false;
  $("start").disabled = true;
  $("cancel").textContent = "Cancel";
  $("total").textContent = "";
  try {
    ({ look, paused } = await invoke("add_folder_info"));
  } catch (error) {
    refuse({ name: "", path: "", refused: String(error) });
    return;
  }
  $("title").textContent = look.kind === "refused" ? "Can't add this folder" : `Add “${look.name}”`;
  $("where").textContent = tilde(look.path);
  switch (look.kind) {
    case "refused":
      refuse(look);
      break;
    case "inside":
      await inside(showing);
      break;
    default:
      await toIndex(showing);
  }
}

function refuse(folder) {
  $("what").textContent = folder.refused;
  $("start").hidden = true;
  $("cancel").textContent = "Close";
  $("cancel").focus();
}

/// A folder DigUp searches already: nothing to index; skipped folders in it can be taken in.
async function inside(showing) {
  const how = look.code ? " in code search (queries that start with code:)" : "";
  const searched = look.within === look.path ? `DigUp searches it already${how}`
    : `It's in ${tilde(look.within)}, which DigUp searches already${how}`;
  $("what").textContent = `${searched}: there's nothing to index. The search panel will search inside it.` + (look.skipped.length ? " These folders in it are skipped; check the ones to take in:" : "");
  $("start").textContent = "Search in It";
  $("start").disabled = false;
  for (const path of look.skipped) $("tree").append(addRow(path, null, 0, false).row);
  refresh();
  focusFirst();
  showTotal();
  // What's in them, as they're counted.
  for (const path of look.skipped) {
    const [answer] = await estimate([path]);
    if (showing !== shown) return;
    const node = nodes.get(path);
    if (node && answer) {
      node.answer = answer;
      node.row.querySelector(".counts").textContent = countsText(answer);
    }
  }
  showTotal();
}

/// A new folder or a repo: its folders, counted, to leave some out.
async function toIndex(showing) {
  $("what").textContent = look.kind === "repo"
    ? "It's a code project (git): it goes into code search, where queries that start with code: find it, as do coding "
      + "tools. Uncheck what to leave out."
    : "DigUp indexes it from now on and keeps it up to date. Uncheck the folders to leave out.";
  $("documents-option").hidden = look.kind !== "repo" || look.documents;
  $("start").textContent = "Add";
  if (paused) note("Indexing is paused: it starts when you resume it (the tray's Resume Indexing).");
  $("total").textContent = "Counting what's in it…";
  const [answer] = await estimate([look.path]);
  if (showing !== shown) return;
  if (!answer || answer.readable === false) {
    refuse({ refused: "DigUp can't read this folder (its permissions don't let you, or it's gone)." });
    return;
  }
  whole = answer;
  addChildren(look.path, answer, 0);
  $("start").disabled = false;
  focusFirst();
  showTotal();
}

/// The folders inside one, as `estimate` found them (biggest first), and a line for the files right in it.
function addChildren(parent, answer, level) {
  const children = (answer.subfolders || []).map((sub) => sub.folder);
  const after = level === 0 ? null : nodes.get(parent).row;
  const node = nodes.get(parent);
  if (node) node.children = children;
  // Each new row goes after the one before it, under the folder they're in.
  let previous = after;
  const place = (row) => {
    if (previous) previous.after(row);
    else $("tree").append(row);
    previous = row;
  };
  for (const sub of answer.subfolders || []) {
    const off = LEFT_OUT.has(nameOf(sub.folder).toLowerCase());
    place(addRow(sub.folder, sub, level, !off).row);
  }
  const loose = filesRightIn(answer);
  if (loose > 0) {
    const row = element("div", "row files");
    row.style.setProperty("--level", level);
    row.append(element("span", "open"), element("span", "name", `${plural(loose, "file", "files")} right in `
      + `${nameOf(parent)}`));
    place(row);
    if (node) node.filesRow = row;
  }
  refresh();
}

/// A folder's row (the caller puts it in its place): ▸ to show the folders inside, its checkbox, its name, what's in
/// it.
function addRow(path, answer, level, checked) {
  const row = element("label", "row");
  row.style.setProperty("--level", level);
  row.setAttribute("role", "treeitem");
  const open = element("button", "open");
  open.type = "button";
  open.tabIndex = -1;
  open.innerHTML = CHEVRON;
  // Inside: the folders listed are skipped ones, taken in or not; their insides aren't for choosing here.
  if (look.kind === "inside") open.style.visibility = "hidden";
  open.onclick = (event) => {
    event.preventDefault();
    toggleOpen(path);
  };
  const box = element("input");
  box.type = "checkbox";
  box.checked = checked;
  box.onchange = () => {
    nodes.get(path).checked = box.checked;
    refresh();
  };
  row.append(open, box, element("span", "name", nameOf(path)),
             element("span", "counts", answer ? countsText(answer) : "Counting…"));
  const node = { answer, checked, open: false, children: null, level, row, box };
  nodes.set(path, node);
  return node;
}

/// Shows or hides the folders inside one (counted the first time).
async function toggleOpen(path) {
  const node = nodes.get(path);
  if (!node || look.kind === "inside") return;
  node.open = !node.open;
  node.row.classList.toggle("expanded", node.open);
  if (node.open && node.children === null) {
    const showing = shown;
    node.children = [];
    const [answer] = await estimate([path]);
    if (showing !== shown || !answer) return;
    addChildren(path, answer, node.level + 1);
    if (!answer.subfolders?.length) node.row.querySelector(".open").style.visibility = "hidden";
  }
  refresh();
}

/// Rows follow their folders: hidden when a folder they're in is closed, disabled when one is unchecked.
function refresh() {
  for (const [path, node] of nodes) {
    const parents = parentsOf(path);
    node.row.hidden = parents.some((parent) => !parent.open);
    node.box.disabled = look.kind !== "inside" && parents.some((parent) => !parent.checked);
    node.row.classList.toggle("off", !node.checked || node.box.disabled);
    if (node.filesRow) node.filesRow.hidden = !node.open || node.row.hidden;
  }
  showTotal();
}

/// The listed folders a folder is in.
function parentsOf(path) {
  const parents = [];
  for (const [other, node] of nodes) if (other !== path && isInside(path, other)) parents.push(node);
  return parents;
}

function disabled(path) {
  return parentsOf(path).some((parent) => !parent.checked);
}

/// The folders left out: unchecked ones whose folders are all checked (what's in them goes with them).
function leftOut() {
  return [...nodes].filter(([path, node]) => !node.checked && !disabled(path)).map(([path]) => path);
}

/// What indexing will read, and about how long its first pass takes, in the footer and on the button.
function showTotal() {
  if (look?.kind === "inside") {
    const taken = [...nodes].filter(([, node]) => node.checked);
    $("start").textContent = taken.length ? "Take In and Search" : "Search in It";
    const files = taken.reduce((sum, [, node]) => sum + filesOf(node.answer), 0);
    $("total").textContent = taken.length ? `${plural(files, "file", "files")} to index` : "";
    return;
  }
  if (!whole) return;
  let files = filesOf(whole), seconds = whole.seconds || 0;
  for (const path of leftOut()) {
    const answer = nodes.get(path).answer;
    files -= filesOf(answer);
    seconds -= answer?.seconds || 0;
  }
  files = Math.max(0, files);
  $("total").textContent = files ? `${plural(files, "file", "files")} · ${duration(seconds)} to index`
    : "Nothing DigUp reads in it";
  $("start").textContent = files ? `Add and Index ${files.toLocaleString()} ${files === 1 ? "File" : "Files"}` : "Add";
  if (files > MANY) note("That's a lot of files: the first pass takes a while. Uncheck what you don't need searched.");
  else if (!paused) $("note").hidden = true;
}

async function add() {
  if ($("start").disabled || $("start").hidden) return;
  $("start").disabled = true;
  const choice = look.kind === "inside"
    ? { takeIn: [...nodes].filter(([, node]) => node.checked).map(([path]) => path) }
    : { skipped: leftOut(), documents: $("documents").checked };
  try {
    await invoke("add_folder", { choice });
  } catch (error) {
    note(String(error));
    $("start").disabled = false;
  }
}

function cancel() {
  invoke("cancel_add").catch(() => {});
}

// MARK: Keys

/// The checkboxes that can take the keyboard, top to bottom.
function boxes() {
  return [...document.querySelectorAll(".row input")].filter((box) => !box.disabled && !box.closest(".row").hidden);
}

function focusFirst() {
  (boxes()[0] ?? ($("start").hidden ? $("cancel") : $("start"))).focus();
}

document.addEventListener("keydown", (event) => {
  const box = event.target.closest?.(".row") ? event.target : null;
  const path = box && [...nodes].find(([, node]) => node.box === box)?.[0];
  switch (event.key) {
    case "Escape":
      event.preventDefault();
      cancel();
      break;
    case "Enter":
      // A button has its own Enter.
      if (event.target.tagName === "BUTTON") return;
      event.preventDefault();
      add();
      break;
    case "ArrowDown":
    case "ArrowUp": {
      const list = boxes();
      if (!list.length) return;
      event.preventDefault();
      const at = list.indexOf(event.target);
      list[Math.max(0, Math.min(list.length - 1, at + (event.key === "ArrowDown" ? 1 : -1)))].focus();
      break;
    }
    case "ArrowRight":
      if (!path) return;
      event.preventDefault();
      if (!nodes.get(path).open) toggleOpen(path);
      else boxes()[boxes().indexOf(box) + 1]?.focus();
      break;
    case "ArrowLeft": {
      if (!path) return;
      event.preventDefault();
      const node = nodes.get(path);
      if (node.open) toggleOpen(path);
      else parentsOf(path).sort((a, b) => b.level - a.level)[0]?.box.focus();
      break;
    }
  }
});

$("start").addEventListener("click", add);
$("cancel").addEventListener("click", cancel);

// MARK: Helpers

async function estimate(folders) {
  try {
    return await invoke("estimate", { folders, code: look.code });
  } catch {
    return [];
  }
}

/// How many files indexing reads in a folder (estimate's counts by kind).
function filesOf(answer) {
  return Object.values(answer?.files || {}).reduce((sum, count) => sum + count, 0);
}

/// The files right in a folder, not in the folders inside it.
function filesRightIn(answer) {
  return filesOf(answer) - (answer.subfolders || []).reduce((sum, sub) => sum + filesOf(sub), 0);
}

/// "1,204 pictures · 37 PDFs · about 3 min"
function countsText(answer) {
  if (answer.readable === false) return "Can't read it";
  const files = answer.files || {};
  if (look.code) {
    const count = filesOf(answer);
    return count ? `${plural(count, "file", "files")} · ${duration(answer.seconds)}` : "Nothing code search reads";
  }
  const part = (count, one, many) => (count ? plural(count, one, many) : null);
  const parts = [
    part((files.image || 0) + (files.screenshot || 0), "picture", "pictures"),
    part(files.pdf, "PDF", "PDFs"),
    part(files.doc, "document", "documents"),
    part(files.audio, "recording", "recordings"),
    part(files.video, "video", "videos"),
  ].filter(Boolean);
  return parts.length ? `${parts.join(" · ")} · ${duration(answer.seconds)}` : "Nothing DigUp reads in it";
}

/// "under a minute", "about 4 min", "about 2 h 10 min"
function duration(seconds) {
  const minutes = Math.round((seconds || 0) / 60);
  if (minutes < 1) return "under a minute";
  if (minutes < 60) return `about ${minutes} min`;
  return `about ${Math.floor(minutes / 60)} h` + (minutes % 60 ? ` ${minutes % 60} min` : "");
}

function plural(count, one, many) {
  return `${count.toLocaleString()} ${count === 1 ? one : many}`;
}

function note(text) {
  $("note").textContent = text;
  $("note").hidden = false;
}

function nameOf(path) {
  return path.split(/[\\/]/).filter(Boolean).pop() || path;
}

function isInside(path, folder) {
  const base = folder.replace(/[\\/]$/, "");
  return path.startsWith(base + "/") || (isWindows && path.startsWith(base + "\\"));
}

function tilde(path) {
  const shown = home && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
  return isWindows ? shown.replaceAll("/", "\\") : shown;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

// Another folder to add while this window is open: it shows that one now.
tauri.event.listen("add-folder", () => start());
tauri.path.homeDir().then((path) => { home = path.replace(/[\\/]$/, ""); }).catch(() => {}).finally(start);
