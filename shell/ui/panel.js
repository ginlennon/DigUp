// The search panel of DigUp's Windows and Linux shell (tried out on the Mac first). Every keystroke shows keyword
// results at once (the last word as a prefix); once typing pauses for 120 ms the meaning results replace them (the
// query was embedded while you typed). Results far weaker than the best are folded under "N weaker matches". The
// helper (`digup search-service`) does the work; the Mac app's panel (Sources/DigUpApp/SearchPanel.swift) is the
// reference for how it behaves.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const ask = (request) => invoke("ask", { request });
const fileURL = (path) => tauri.core.convertFileSrc(path);

const TYPING_PAUSE = 120;          // ms after the last keystroke until the meaning results show
const ROWS_PER_GROUP = 6;
const FIELD_HEIGHT = 56;
const PANEL_HEIGHT = 480;
const WEAKER = "\u0000weaker";     // the selectable row that folds and unfolds the weaker matches
const isMac = /Mac/.test(navigator.platform);
const isWindows = /Win/.test(navigator.platform);
const MOD = isMac ? "⌘" : "Ctrl+";
const FILE_MANAGER = isMac ? "Finder" : isWindows ? "Explorer" : "Files";
// Pictures every web view shows as they are; anything else (HEIC, TIFF, RAW…) comes as JPEG from the helper.
const SHOWN_AS_IS = new Set(["jpg", "jpeg", "png", "gif", "webp", "bmp"]);
const GROUP_OF = { screenshot: "Screenshots", image: "Images", pdf: "Documents", doc: "Documents", video: "Video",
                   audio: "Audio", code: "Code" };
const KIND_TITLE = { screenshot: "Screenshot", image: "Image", pdf: "PDF", doc: "Document", audio: "Audio",
                     video: "Video", code: "Code" };

const $ = (id) => document.getElementById(id);
const $query = $("query"), $body = $("body"), $list = $("list"), $preview = $("preview");
const $footer = $("footer"), $summary = $("summary"), $keys = $("keys"), $activity = $("activity");
const $chips = $("chips");

/// A query that starts with in:<folder> and a space searches inside that folder: the folder becomes a chip before the
/// field and the rest is the query (the shell finds the folder: scope.rs). `in:` comes first and `code:` after it
/// ("in:billing code: retry"), since `code:` is always the start of what's searched.
const SCOPE = /^\s*in:(?:"([^"]*)"|([^"\s]\S*))\s/i;
const SCOPE_TYPING = /^\s*in:(?:"[^"]*"?|\S*)$/i;   // the folder is still being typed

const state = {
  generation: 0,
  finalGeneration: -1,   // the generation whose meaning results are showing: late keyword results don't replace them
  timer: null,
  phase: "empty",        // empty | words | meaning | wordsOnly | codeHint | scopeHint | scopeProblem | similarWaiting
                         // | similar
  text: "",              // what was searched (without "code:")
  scope: null,           // the folder searched in ({path, name, ambiguous}), or null: all of them
  scopeProblem: null,    // what the panel says when in: names no chosen folder
  like: null,            // the file whose similar files are showing ({path, name}), or null
  before: "",            // what the field had before them
  isCode: false,
  strong: [],
  weaker: [],
  groups: [],
  showWeaker: false,
  selection: null,       // a result's path, or WEAKER
  navigated: false,      // the arrow keys moved the selection since the last edit
  encoder: "stopped",
  height: FIELD_HEIGHT,
  home: "",
  error: null,
  indexing: null,        // {done, total} while the index helper works through new files
};
let debugPending = false;

// MARK: Searching

function queryChanged() {
  const generation = ++state.generation;
  clearTimeout(state.timer);
  state.navigated = false;
  state.error = null;
  state.scopeProblem = null;
  const scoped = SCOPE.exec($query.value);
  if (scoped) {
    takeScope(scoped, generation);
    return;
  }
  if (SCOPE_TYPING.test($query.value)) {
    show({ hits: [], strong: 0 }, "", "scopeHint");
    return;
  }
  const typed = $query.value.trim();
  const code = /^code:/i.test(typed);
  const text = code ? typed.slice(5).trim() : typed;
  const folders = state.scope ? [state.scope.path] : undefined;
  state.isCode = code;
  if (!typed || (code && !text)) {
    show({ hits: [], strong: 0 }, text, typed ? "codeHint" : "empty");
    return;
  }
  // Words now. The last word is probably half-typed, so it matches as a prefix.
  ask({ op: "search", q: text, code, meaning: false, prefix_last: true, limit: 40, folders })
    .then((reply) => {
      if (generation === state.generation && state.finalGeneration !== generation) show(reply, text, "words");
    })
    .catch(failed);
  // The meaning is embedded now, so its vector is ready when typing pauses: the pause is the whole wait.
  ask({ op: "embed_ahead", q: text, code }).catch(() => {});
  state.timer = setTimeout(() => {
    ask({ op: "search", q: text, code, meaning: true, limit: 40, folders })
      .then((reply) => {
        if (generation !== state.generation) return;
        state.finalGeneration = generation;
        show(reply, text, reply.meaning ? "meaning" : "wordsOnly");
        if (debugPending) report();
      })
      .catch(failed);
  }, TYPING_PAUSE);
}

/// The query's in:<folder>: found, it becomes the chip and what follows it is searched; not found, the panel says so
/// and the text stays as typed.
async function takeScope(match, generation) {
  let folder;
  try {
    folder = await invoke("resolve_folder", { name: match[1] ?? match[2] });
  } catch (error) {
    if (generation !== state.generation) return;
    state.scopeProblem = String(error);
    show({ hits: [], strong: 0 }, "", "scopeProblem");
    return;
  }
  // Typing went on meanwhile: the in: is still at the start (an edit there starts another lookup).
  if (!$query.value.startsWith(match[0])) return;
  state.scope = folder;
  $query.value = $query.value.slice(match[0].length);
  $query.setSelectionRange($query.value.length, $query.value.length);
  renderChips();
  queryChanged();
}

function removeScope() {
  state.scope = null;
  renderChips();
  if (state.like) findSimilar();
  else queryChanged();
  $query.focus();
}

// MARK: More like this

/// Ctrl+L (or More Like This) on a result: the files most like it, by meaning alone (search-service's `similar`), in the
/// folder chip's folder if there is one. A "Like <name>" chip stands for it; Esc, Backspace at the field's start or the
/// chip's × go back to the query before, and typing searches what's typed.
function moreLike(hit) {
  // Code search's results aren't in the index `similar` looks through.
  if (!hit || state.isCode) return;
  if (!state.like) state.before = $query.value;
  state.like = { path: hit.path, name: nameOf(hit.path) };
  $query.value = "";
  renderChips();
  findSimilar();
}

function findSimilar() {
  const generation = ++state.generation;
  clearTimeout(state.timer);
  state.navigated = false;
  state.error = null;
  state.isCode = false;
  show({ hits: [], strong: 0 }, "", "similarWaiting");
  const folders = state.scope ? [state.scope.path] : undefined;
  ask({ op: "similar", path: state.like.path, limit: 40, folders })
    .then((reply) => {
      if (generation !== state.generation) return;
      state.finalGeneration = generation;
      show(reply, "", "similar");
    })
    .catch(failed);
}

/// Leaves the similar files: back to the query typed before them (`back`), or on to what's being typed now.
function leaveLike(back) {
  state.like = null;
  renderChips();
  if (back) {
    $query.value = state.before ?? "";
    $query.setSelectionRange($query.value.length, $query.value.length);
    queryChanged();
  }
}

function show(reply, text, phase) {
  const hits = reply.hits || [];
  const strong = Math.min(reply.strong ?? hits.length, hits.length);
  state.text = text;
  state.phase = phase;
  state.strong = hits.slice(0, strong);
  state.weaker = hits.slice(strong);
  // Grouped by kind, the best hit's group first; code is one group with the room of all of them.
  const groups = new Map();
  for (const hit of state.strong) {
    const title = GROUP_OF[hit.kind] || "Files";
    if (!groups.has(title)) groups.set(title, []);
    groups.get(title).push(hit);
  }
  const perGroup = state.isCode ? ROWS_PER_GROUP * 3 : ROWS_PER_GROUP;
  state.groups = [...groups].map(([title, rows]) => ({ title, rows: rows.slice(0, perGroup), total: rows.length }));
  if (!state.navigated) state.showWeaker = false;
  // Follow the top hit until you pick something with the arrow keys.
  const ids = rowIDs();
  if (!state.navigated || !ids.includes(state.selection)) state.selection = ids[0] ?? null;
  render();
}

function failed(error) {
  state.error = String(error);
  renderFooter();
}

function rowIDs() {
  return [
    ...state.groups.flatMap((group) => group.rows.map((hit) => hit.path)),
    ...(state.weaker.length ? [WEAKER] : []),
    ...(state.showWeaker ? state.weaker.map((hit) => hit.path) : []),
  ];
}

function selectedHit() {
  return [...state.strong, ...state.weaker].find((hit) => hit.path === state.selection) ?? null;
}

function move(step) {
  const ids = rowIDs();
  if (!ids.length) return;
  const index = ids.indexOf(state.selection);
  state.selection = ids[Math.max(0, Math.min(ids.length - 1, (index < 0 ? -1 : index) + step))];
  state.navigated = true;
  render();
}

function toggleWeaker() {
  state.showWeaker = !state.showWeaker;
  state.selection = WEAKER;
  render();
}

/// Opens it at the page, moment or line when its app can be told it (the query says what to search for on a page).
function openSelected() {
  const hit = selectedHit();
  if (hit) invoke("open_hit", { hit, query: state.text }).catch(failed);
}

/// What ↩ does with a result: "Open at p. 3" or "Open at 0:06" only when the app it opens in can go there (its
/// default app, or VLC for a recording when Settings say so), else "Open".
/// The shell's answer comes a moment later (it looks the app up), so this says "Open" until then and redraws.
const openTitles = new Map();
function openTitle(hit) {
  if (!hit) return "Open";
  const key = `${hit.path}|${hit.segment}|${hit.loc}`;
  if (!openTitles.has(key)) {
    openTitles.set(key, "Open");
    invoke("open_title", { hit })
      .then((title) => {
        openTitles.set(key, title);
        const now = selectedHit();
        if (title === "Open" || !now || `${now.path}|${now.segment}|${now.loc}` !== key) return;
        renderFooter();
        const button = $preview.querySelector("button.open");
        if (button) button.textContent = title;
      })
      .catch(() => {});
  }
  return openTitles.get(key);
}

function revealSelected() {
  const hit = selectedHit();
  if (hit) invoke("reveal", { path: hit.path }).catch(failed);
}

// MARK: Drawing

function render() {
  const empty = state.phase === "empty";
  const height = empty ? FIELD_HEIGHT : PANEL_HEIGHT;
  if (height !== state.height) {
    state.height = height;
    invoke("panel_height", { height }).catch(() => {});
  }
  $body.hidden = empty;
  $footer.hidden = empty;
  if (empty) return;
  renderList();
  renderPreview();
  renderFooter();
}

function renderList() {
  $list.replaceChildren();
  const nothing = !state.strong.length && !state.weaker.length;
  $list.hidden = nothing;
  if (nothing) return;
  for (const group of state.groups) {
    $list.append(element("div", "group-title", group.title));
    for (const hit of group.rows) $list.append(row(hit));
  }
  if (state.weaker.length) {
    const fold = element("div", "weaker" + (state.showWeaker ? " open" : "") + (state.selection === WEAKER ? " selected" : ""));
    fold.innerHTML = ICONS.chevron;
    const count = state.weaker.length;
    fold.append(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`);
    fold.onclick = toggleWeaker;
    $list.append(fold);
    if (state.showWeaker) for (const hit of state.weaker) $list.append(row(hit));
  }
  $list.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
}

function row(hit) {
  const item = element("div", "row" + (state.selection === hit.path ? " selected" : ""));
  item.setAttribute("role", "option");
  item.append(thumbnail(hit));
  const text = element("div", "row-text");
  const title = element("div", "row-title");
  title.append(element("span", "name", nameOf(hit.path)));
  const place = placeOf(hit);
  if (place) title.append(element("span", "badge", place));
  const sub = element("div", "row-sub");
  // The words found, where keyword search found them; else where the file is.
  if (hit.excerpt && hit.excerpt.includes("«")) sub.innerHTML = marked(hit.excerpt);
  else sub.textContent = folderOf(hit);
  text.append(title, sub);
  item.append(text);
  item.onclick = () => {
    state.selection = hit.path;
    state.navigated = true;
    render();
  };
  item.ondblclick = openSelected;
  return item;
}

/// A picture of the file for its row: the picture itself, a video's frame at the moment, a PDF's page; else its
/// kind's icon. All come small from the helper (a full-size photo per row would cost the web view hundreds of MB).
function thumbnail(hit) {
  const pixels = Math.round(36 * (window.devicePixelRatio || 1));
  const what = hit.kind === "image" || hit.kind === "screenshot" ? ["image", null]
    : hit.kind === "video" ? ["video", hit.loc ?? 0.5]
    : hit.kind === "pdf" ? ["pdf", hit.segment === "page" || hit.segment === "page_image" ? hit.loc : 1]
    : null;
  if (!what) return kindIcon(hit.kind);
  const image = element("img", "thumb");
  image.alt = "";
  rendered(hit.path, what[0], what[1], pixels)
    .then((path) => { image.src = fileURL(path); })
    .catch(() => image.replaceWith(kindIcon(hit.kind)));
  return image;
}

function renderPreview() {
  $preview.replaceChildren();
  if (!state.strong.length && !state.weaker.length) {
    const inside = state.scope ? ` in ${state.scope.name}` : "";
    if (state.phase === "codeHint") {
      $preview.append(message("Search your code", "Say what the code does, or type a name that's in it."));
    } else if (state.phase === "scopeHint") {
      $preview.append(message("Search inside a folder", "Name one of your folders, or a folder right inside one, "
        + "then what you're looking for: in:Documents invoice, in:~/Pictures/2026 beach, in:\"Big Folder\" notes."));
    } else if (state.phase === "similarWaiting") {
      $preview.append(message(`Looking for files like ${state.like.name}…`,
        "A file that isn't in the index yet is read first, which takes a few seconds."));
    } else if (state.phase === "similar") {
      $preview.append(message(`Nothing much like ${state.like.name}${inside}`,
        "Press Esc to go back to your search."));
    } else if (state.phase === "scopeProblem") {
      $preview.append(message(state.scopeProblem, "in: looks among the folders DigUp searches (Settings) and the "
        + "folders right inside them, or takes a path: in:~/Documents/Trips."));
    } else if (state.indexing) {
      const { done, total } = state.indexing;
      $preview.append(message("Nothing yet", `Still indexing (${done} of ${total} files). Until a file is read, `
        + "DigUp finds it only by its name."));
    } else if (state.isCode) {
      $preview.append(message(`No good matches in your code${inside}`,
        "Try saying what the code does, or a name that's in it."));
    } else {
      $preview.append(message(`No good matches${inside}`,
        "Try what you'd see or hear in it, or words you remember from it."));
    }
    return;
  }
  if (state.selection === WEAKER) {
    const count = state.weaker.length;
    $preview.append(message(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`,
      "They match much less well than the results above. Press Return to " + (state.showWeaker ? "fold them away." : "show them.")));
    return;
  }
  const hit = selectedHit();
  if (!hit) return;
  $preview.append(picture(hit), facts(hit));
}

/// The big picture: the photo or screenshot, the frame at the moment (it plays from there), the page, what's heard
/// at the moment, or the passage that matched.
function picture(hit) {
  const frame = element("div", "picture");
  const image = element("img");
  image.alt = "";
  frame.append(image);
  switch (hit.kind) {
    case "image":
    case "screenshot":
      if (SHOWN_AS_IS.has(extensionOf(hit.path))) image.src = fileURL(hit.path);
      else rendered(hit.path, "image", null, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "pdf":
      rendered(hit.path, "pdf", hit.loc ?? 1, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "video": {
      // The frame at the moment, its time on it; a click plays the video from there.
      const at = hit.loc ?? 0;
      rendered(hit.path, "video", at, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      const moment = element("div", "moment");
      const play = element("div", "play");
      play.innerHTML = ICONS.play;
      moment.append(image, play, element("span", "at", clock(at)));
      frame.replaceChildren(moment);
      frame.onclick = () => {
        const video = element("video");
        video.src = `${fileURL(hit.path)}#t=${at}`;
        video.controls = true;
        video.autoplay = true;
        frame.replaceChildren(video);
      };
      return frame;
    }
    case "audio": {
      const audio = element("div", "audio-picture");
      audio.innerHTML = ICONS.audio;
      const player = element("audio");
      player.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
      player.controls = true;
      player.preload = "metadata";
      audio.append(player);
      frame.replaceChildren(audio);
      return frame;
    }
    default: {
      const passage = element("div", "passage" + (hit.kind === "code" ? " code" : ""));
      passage.textContent = (hit.excerpt ?? "").replace(/[«»]/g, "");
      ask({ op: "text", segment: hit.segment_id, code: state.isCode })
        .then((reply) => { if (reply.text) passage.innerHTML = highlighted(reply.text, state.text); })
        .catch(() => {});
      return passage;
    }
  }
}

function facts(hit) {
  const box = element("div", "facts");
  box.append(element("div", "title", nameOf(hit.path)), element("div", "line", folderOf(hit)),
             element("div", "line", details(hit)));
  const reason = element("div", "reason");
  reason.innerHTML = ICONS.found;
  reason.append(element("span", "", reasonOf(hit)));
  box.append(reason);
  if (hit.excerpt && hit.excerpt.includes("«") && hit.kind !== "doc" && hit.kind !== "code") {
    const words = element("div", "reason-text");
    words.innerHTML = marked(hit.excerpt);
    box.append(words);
  }
  const buttons = element("div", "buttons");
  const open = element("button", "open", openTitle(hit));
  open.onclick = openSelected;
  const reveal = element("button", "", `Show in ${FILE_MANAGER}`);
  reveal.onclick = revealSelected;
  buttons.append(open, reveal);
  if (!state.isCode) {
    const like = element("button", "", "More Like This");
    like.title = `${MOD}L`;
    like.onclick = () => moreLike(hit);
    buttons.append(like);
  }
  box.append(buttons);
  return box;
}

function renderFooter() {
  const strong = state.strong.length, weaker = state.weaker.length;
  let summary;
  if (state.error) summary = `DigUp's helper: ${state.error}`;
  else if (state.phase === "words") {
    summary = state.encoder === "starting" ? "Matching words; meaning search is warming up…" : "Matching words…";
  } else if (state.phase === "wordsOnly") summary = "Words only: meaning search isn't available";
  else if (state.phase === "codeHint") summary = "Searching your code";
  else if (state.phase === "scopeHint") summary = "Searching inside a folder";
  else if (state.phase === "scopeProblem") summary = "No folder to search in";
  else if (state.phase === "similarWaiting") summary = "Looking for similar files…";
  else summary = `${strong} ${strong === 1 ? "result" : "results"}` + (weaker ? ` · ${weaker} weaker` : "");
  // Results while indexing are partial: say so where they're counted.
  if (state.indexing && !state.error) summary += ` · still indexing (${state.indexing.done} of ${state.indexing.total})`;
  $summary.textContent = summary;
  const hit = selectedHit();
  $keys.textContent = `↩ ${openTitle(hit)}   ${MOD}↩ Show in ${FILE_MANAGER}`
    + (hit && !state.isCode ? `   ${MOD}L More like this` : "");
}

/// The chips before the field: the folder searched in, and the file whose similar files are showing; removed with their
/// × or (the last one) with Backspace at the field's start.
function renderChips() {
  const chips = [];
  if (state.scope) {
    // Another folder has the same name: the path says which one this is.
    const name = state.scope.ambiguous ? tilde(state.scope.path) : state.scope.name;
    chips.push(chip(`in ${name}`, tilde(state.scope.path), removeScope));
  }
  if (state.like) chips.push(chip(`Like ${state.like.name}`, tilde(state.like.path), () => leaveLike(true)));
  $chips.replaceChildren(...chips);
  $chips.hidden = !chips.length;
}

function chip(text, title, remove) {
  const node = element("span", "chip");
  node.title = title;
  node.append(element("span", "", text));
  const close = element("button", "", "×");
  close.tabIndex = -1;
  close.setAttribute("aria-label", `Remove “${text}”`);
  close.onmousedown = (event) => event.preventDefault();   // the field keeps the keyboard
  close.onclick = remove;
  node.append(close);
  return node;
}

function message(title, text) {
  const box = element("div", "message");
  box.append(element("strong", "", title), element("span", "", text));
  return box;
}

// MARK: What a result says

/// The page or moment that matched, as a badge: "p. 3", "0:06", "♪ 0:25" (a video's sound), "L12–40" (code).
function placeOf(hit) {
  if (hit.loc == null) return null;
  switch (hit.segment) {
    case "page":
    case "page_image": return `p. ${Math.trunc(hit.loc)}`;
    case "frame": return clock(hit.loc);
    case "audio": return hit.kind === "video" ? `♪ ${clock(hit.loc)}` : clock(hit.loc);
    case "lines": {
      const first = Math.trunc(hit.loc), last = Math.trunc(hit.loc_end ?? hit.loc);
      return first === last ? `L${first}` : `L${first}–${last}`;
    }
    case "cells": return span(hit);
    default: return null;
  }
}

function span(hit) {
  if (hit.loc == null) return null;
  const first = Math.trunc(hit.loc), last = Math.trunc(hit.loc_end ?? hit.loc);
  const what = hit.segment === "cells" ? ["cell", "cells"] : ["line", "lines"];
  return first === last ? `${what[0]} ${first}` : `${what[1]} ${first}–${last}`;
}

/// Why it's here, in a few words: "Matches the picture", "Matches the frame at 0:06".
function reasonOf(hit) {
  if (state.phase === "similar" && state.like) {
    const place = placeOf(hit);
    return `Like ${state.like.name}` + (place ? ` at ${place}` : "");
  }
  const meaning = (hit.z ?? 0) >= 2, words = hit.keyword_rank != null;
  if (!meaning) return words ? "Has your words" : "Matches its name";
  const at = hit.loc != null ? clock(hit.loc) : "";
  const page = hit.loc != null ? `page ${Math.trunc(hit.loc)}` : "a page";
  switch (hit.segment) {
    case "image": return hit.kind === "screenshot" ? "Matches what's on screen" : "Matches the picture";
    case "ocr": return "Matches the text in it";
    case "frame": return `Matches the frame at ${at}`;
    case "audio": return hit.kind === "video" ? `Matches the sound at ${at}` : `Matches what's heard at ${at}`;
    case "page": return `Matches the text on ${page}`;
    case "page_image": return `Matches ${page}`;
    case "chunk": return "Matches its text";
    case "lines":
    case "cells": return `Matches ${span(hit) ?? "the code"}`;
    default: return "Matches its name";
  }
}

/// "Screenshot · Oct 7, 2026 · 1440 × 900 · 62 KB", "PDF · … · 463 pages, 120 read so far · 23 MB"
function details(hit) {
  const info = hit.info || {};
  const parts = [KIND_TITLE[hit.kind] || "File", dateOf(hit.modified)];
  if (info.width && info.height) parts.push(`${info.width} × ${info.height}`);
  const readTo = info.read_to != null ? Number(info.read_to) : null;
  if (info.pages) {
    const pages = Number(info.pages);
    parts.push((pages === 1 ? "1 page" : `${pages.toLocaleString()} pages`) + (readTo != null ? `, ${readTo} read so far` : ""));
  } else if (readTo != null) parts.push("partly read so far");
  if (info.lines) parts.push(Number(info.lines) === 1 ? "1 line" : `${Number(info.lines).toLocaleString()} lines`);
  if (info.duration) parts.push(clock(Number(info.duration)));
  if (hit.size > 0) parts.push(bytes(hit.size));
  return parts.join(" · ");
}

function nameOf(path) {
  return path.split(/[\\/]/).pop();
}

function extensionOf(path) {
  const name = nameOf(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/// Where the file is: "~/Downloads/Screenshots"; code says where it is in its repo: "billing/payments".
function folderOf(hit) {
  const folder = hit.path.slice(0, Math.max(0, hit.path.search(/[\\/][^\\/]*$/)));
  const repo = hit.info?.repo;
  if (hit.kind === "code" && repo && hit.path.startsWith(repo + "/")) {
    return folder.slice(repo.slice(0, repo.search(/[\\/][^\\/]*$/)).length + 1);
  }
  return tilde(folder);
}

/// "~/Pictures/2026" for a folder in the home folder.
function tilde(folder) {
  const shown = state.home && folder.startsWith(state.home) ? "~" + folder.slice(state.home.length) : folder;
  return isWindows ? shown.replaceAll("/", "\\") : shown;
}

function clock(seconds) {
  const total = Math.trunc(seconds);
  const two = (n) => String(n).padStart(2, "0");
  return total >= 3600 ? `${Math.trunc(total / 3600)}:${two(Math.trunc(total / 60) % 60)}:${two(total % 60)}`
                       : `${Math.trunc(total / 60)}:${two(total % 60)}`;
}

function dateOf(seconds) {
  return new Date(seconds * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

/// Sizes the way file managers count them (1 KB = 1,000 bytes): "62 KB", "2.1 MB".
function bytes(count) {
  if (count < 1000) return `${count} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = count / 1000, unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

/// An excerpt with the words keyword search found (marked « ») in bold.
function marked(excerpt) {
  return escaped(excerpt).replace(/«([^»]*)»/g, "<b>$1</b>");
}

/// A passage with the query's words marked where they start a word.
function highlighted(text, query) {
  const words = [...new Set(query.toLowerCase().split(/[^\p{L}\p{N}_]+/u).filter((word) => word.length > 1))];
  let html = escaped(text);
  if (!words.length) return html;
  const pattern = new RegExp(`(?<![\\p{L}\\p{N}])(${words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "giu");
  return html.replace(pattern, "<mark>$1</mark>");
}

function escaped(text) {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function kindIcon(kind) {
  const icon = element("div", "thumb icon");
  icon.innerHTML = ICONS[kind] || ICONS.doc;
  return icon;
}

/// The helper's JPEG of a page, a frame or a picture, asked for once per file and place.
const renders = new Map();
function rendered(path, kind, loc, pixels) {
  const key = `${path}|${kind}|${loc}|${pixels}`;
  if (!renders.has(key)) renders.set(key, ask({ op: "render", path, kind, loc, pixels }).then((reply) => reply.image));
  return renders.get(key);
}

const ICONS = {
  chevron: '<svg class="chevron" viewBox="0 0 16 16" width="12" height="12"><path d="M6 3.5 L10.5 8 L6 12.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  play: '<svg viewBox="0 0 20 20"><path d="M5 3 L17 10 L5 17 Z"/></svg>',
  found: '<svg viewBox="0 0 24 24"><circle cx="10" cy="10" r="6.5"/><path d="M15 15 L20.5 20.5 M10 7 V13 M7 10 H13"/></svg>',
  doc: '<svg viewBox="0 0 24 24"><path d="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 12 H16 M9 15 H16 M9 18 H13"/></svg>',
  pdf: '<svg viewBox="0 0 24 24"><path d="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 13 H16 M9 16 H14"/></svg>',
  code: '<svg viewBox="0 0 24 24"><path d="M9 7 L4 12 L9 17 M15 7 L20 12 L15 17"/></svg>',
  audio: '<svg viewBox="0 0 24 24"><path d="M3 12 H5 M7 8 V16 M10 5 V19 M13 9 V15 M16 6 V18 M19 10 V14 M21 12 H22"/></svg>',
  video: '<svg viewBox="0 0 24 24"><path d="M4 6 H15 V18 H4 Z M15 10 L20 7 V17 L15 14"/></svg>',
  image: '<svg viewBox="0 0 24 24"><path d="M4 5 H20 V19 H4 Z M4 16 L9 11 L13 15 L16 12 L20 16"/></svg>',
};
ICONS.screenshot = ICONS.image;

// MARK: Keys and events

$query.addEventListener("input", () => {
  // Typing over similar files searches what's typed.
  if (state.like) leaveLike(false);
  queryChanged();
});

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return; // an input method is composing: its keys
  const modifier = isMac ? event.metaKey : event.ctrlKey;
  if (modifier && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "l") {
    event.preventDefault();
    moreLike(selectedHit());
    return;
  }
  switch (event.key) {
    case "Escape":
      event.preventDefault();
      // Similar files go back to the search before them; else the panel steps away.
      if (state.like) leaveLike(true);
      else invoke("hide_panel").catch(() => {});
      break;
    case "ArrowDown":
    case "ArrowUp":
      if (event.altKey || event.shiftKey || modifier) return;
      event.preventDefault();
      move(event.key === "ArrowDown" ? 1 : -1);
      break;
    case "Enter":
      event.preventDefault();
      if (modifier) revealSelected();
      else if (state.selection === WEAKER) toggleWeaker();
      else openSelected();
      break;
    case "Backspace":
      // At the field's very start (nothing selected): the chip before it goes, the last one first.
      if ($query.selectionStart !== 0 || $query.selectionEnd !== 0) break;
      if (state.like) {
        event.preventDefault();
        leaveLike(true);
      } else if (state.scope) {
        event.preventDefault();
        removeScope();
      }
      break;
  }
});

tauri.event.listen("panel-shown", () => {
  openTitles.clear();   // a default app may have changed since
  // Like Spotlight: the last query, selected.
  $query.focus();
  $query.select();
  ask({ op: "prewarm" }).catch(() => {});
});

tauri.event.listen("helper", ({ payload }) => {
  const { from, event } = payload;
  if (from === "search" && event.event === "encoder") {
    state.encoder = event.state;
    if (state.phase !== "empty") renderFooter();
  }
  if (from === "index") {
    if (event.event === "file" && event.total) {
      state.indexing = { done: event.done, total: event.total };
      $activity.textContent = `Indexing ${event.done}/${event.total}`;
      $activity.hidden = false;
    } else if (event.event === "idle" || event.event === "exit") {
      state.indexing = null;
      $activity.hidden = true;
    }
    if (state.phase !== "empty") renderFooter();
  }
});

tauri.path.homeDir().then((home) => { state.home = home.replace(/[\\/]$/, ""); }).catch(() => {});

// Debug runs (--debug-query): type the query in, and once the meaning results and their pictures are in, report
// what the panel shows.
function debugSearch(query) {
  if (!query) return;
  debugPending = true;
  $query.value = query;
  queryChanged();
}
invoke("debug_query").then(debugSearch);
tauri.event.listen("debug-query", ({ payload }) => debugSearch(payload));   // after setup's first index

function report() {
  debugPending = false;
  setTimeout(() => {
    const big = $preview.querySelector("img, video, audio, .passage");
    const thumbs = [...$list.querySelectorAll("img.thumb")];
    invoke("debug_report", {
      report: {
        query: $query.value,
        scope: state.scope && state.scope.path,
        like: state.like && state.like.path,
        phase: state.phase,
        groups: state.groups.map((group) => ({ title: group.title, rows: group.rows.map((hit) => nameOf(hit.path)) })),
        weaker: state.weaker.length,
        selected: state.selection && nameOf(state.selection),
        preview: big && {
          tag: big.tagName.toLowerCase(),
          loaded: big.tagName === "IMG" ? big.complete && big.naturalWidth > 0 : null,
          size: big.tagName === "IMG" ? `${big.naturalWidth}x${big.naturalHeight}` : null,
          text: big.classList.contains("passage") ? big.textContent.slice(0, 80) : null,
        },
        thumbnails: `${thumbs.filter((image) => image.complete && image.naturalWidth > 0).length} of ${thumbs.length} drawn`,
        facts: [...$preview.querySelectorAll(".facts .title, .facts .line, .reason span")].map((node) => node.textContent),
        footer: [$summary.textContent, $keys.textContent],
      },
    }).catch(() => {});
  }, 1500);
}
