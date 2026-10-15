//! Tools that add folders (PLANS/FOLDERS_PLAN.md, A4): an MCP server or the HTTP API started with
//! `--allow-add-folders` asks the running DigUp to add a folder, over the session bus (`serve`: the name
//! "<identifier>.Tools", beside the single-instance one), and DigUp adds it without a window: the add window's rules
//! (adding.rs), and these on top:
//! - inside the home folder only, never a hidden folder or one in it, nor one the person left out in Settings;
//! - at most so many files (`count`, before anything starts): a bigger folder is for the add window, which shows the
//!   counts and lets subfolders be left out;
//! - what the add window starts unchecked is left out (`LEFT_OUT`);
//! - a notification says which tool added what, with Undo (`Change` puts the settings back).
//!
//! `Status` tells a tool how indexing goes (`Progress`), so it can say its results are partial.
//!
//! The session bus is the person's own: any program of theirs can call this, as any can write the settings file. The
//! opt-in is the tool's flag; the notification and Undo make each add visible.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]   // the bus is Linux's; elsewhere only the tests use this

use crate::settings::Settings;
use serde_json::{json, Value};
use std::path::Path;
use std::time::{Duration, Instant};

/// How many files a tool may add at most, unless it says otherwise (the tool's `--max-files`).
pub const MAX_FILES: u32 = 20_000;

/// Folder names left out of a folder a tool adds: what the add window starts unchecked (add.js's LEFT_OUT) and the
/// crawler would read. Hidden ones, node_modules, venv and __pycache__ are never read anyway.
const LEFT_OUT: &[&str] = &["target", "build", "dist", "cache", "caches"];

/// Folders the crawler never walks into (Rules.skippedFolderNames), so their files don't count.
const NEVER_READ: &[&str] = &["node_modules", "bower_components", "venv", "site-packages", "__pycache__",
                              "DerivedData", "Pods", "Carthage"];

/// How long counting may take: a folder that can't be counted in time is too big for a tool.
pub const COUNT_TIME: Duration = Duration::from_secs(10);

/// The name a notification shows for a tool ("claude-code"): letters, digits, spaces and `.-_()` only, at most 40
/// characters; "A tool" when nothing is left.
pub fn tool_name(raw: &str) -> String {
    let kept: String = raw.chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .filter(|c| c.is_alphanumeric() || matches!(c, ' ' | '.' | '-' | '_' | '(' | ')'))
        .take(40)
        .collect();
    let kept = kept.split_whitespace().collect::<Vec<_>>().join(" ");
    if kept.is_empty() { "A tool".to_string() } else { kept }
}

/// `/home/me/git/app` → `~/git/app`, as the notification shows it.
pub fn shown(path: &Path, home: Option<&Path>) -> String {
    match home.and_then(|home| path.strip_prefix(home).ok()) {
        Some(rest) if !rest.as_os_str().is_empty() => format!("~/{}", rest.display()),
        _ => path.display().to_string(),
    }
}

/// Why a tool may not add `folder` (absolute, its links resolved), on top of the add window's reasons (adding.rs).
pub fn refused(folder: &Path, home: Option<&Path>, settings: &Settings) -> Option<String> {
    let shown = folder.display();
    let Some(home) = home else { return Some("DigUp can't tell where your home folder is.".into()) };
    let Ok(inside) = folder.strip_prefix(home) else {
        return Some(format!("{shown} isn't in your home folder: tools may only add folders inside it."));
    };
    if inside.as_os_str().is_empty() {
        return Some("That's your whole home folder: tools may only add folders inside it.".into());
    }
    if inside.components().any(|part| part.as_os_str().to_string_lossy().starts_with('.')) {
        return Some(format!("{shown} is a hidden folder (or in one): tools don't add those."));
    }
    for skip in settings.skipped.iter().chain(&settings.code_skipped) {
        if folder.starts_with(skip) {
            return Some(format!("{shown} is left out in DigUp's settings ({skip}): take it in there if you want it \
                                 searched."));
        }
    }
    None
}

/// What's in a folder a tool adds, counted before anything starts.
#[derive(Debug, PartialEq)]
pub struct Count {
    /// The files DigUp could read (hidden folders, never-read and left-out folders aside), up to the cap + 1.
    pub files: u64,
    /// More than the cap, or not counted in time.
    pub over: bool,
    /// Counting took too long.
    pub slow: bool,
    /// The `LEFT_OUT` folders found, to skip.
    pub left_out: Vec<String>,
}

/// Counts `folder`'s files, stopping past `cap` or at `deadline`. Links aren't followed (the crawler doesn't).
pub fn count(folder: &Path, cap: u64, deadline: Instant) -> Count {
    let mut count = Count { files: 0, over: false, slow: false, left_out: Vec::new() };
    let mut waiting = vec![folder.to_path_buf()];
    while let Some(dir) = waiting.pop() {
        if Instant::now() > deadline {
            count.over = true;
            count.slow = true;
            break;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                if LEFT_OUT.contains(&name.as_str()) {
                    count.left_out.push(entry.path().display().to_string());
                } else if !NEVER_READ.contains(&name.as_str()) {
                    waiting.push(entry.path());
                }
            } else if kind.is_file() {
                count.files += 1;
                if count.files > cap {
                    count.over = true;
                    return count;
                }
            }
        }
    }
    count.left_out.sort();
    count
}

/// What an add changed in the settings, to take back with Undo.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Change {
    pub folders: Vec<String>,
    pub skipped: Vec<String>,
    pub code_folders: Vec<String>,
    pub code_skipped: Vec<String>,
    /// Skips the add took away (a skipped folder taken in).
    pub unskipped: Vec<String>,
    pub code_unskipped: Vec<String>,
}

fn added(before: &[String], after: &[String]) -> Vec<String> {
    after.iter().filter(|item| !before.contains(item)).cloned().collect()
}

impl Change {
    pub fn between(before: &Settings, after: &Settings) -> Change {
        Change {
            folders: added(&before.folders, &after.folders),
            skipped: added(&before.skipped, &after.skipped),
            code_folders: added(&before.code_folders, &after.code_folders),
            code_skipped: added(&before.code_skipped, &after.code_skipped),
            unskipped: added(&after.skipped, &before.skipped),
            code_unskipped: added(&after.code_skipped, &before.code_skipped),
        }
    }

    /// Takes the add back: what it put in goes (what's still there), what it took out comes back. Changes made since
    /// to other folders stay. True when anything changed.
    pub fn undo(&self, settings: &mut Settings) -> bool {
        let before = settings.clone();
        let drop = |list: &mut Vec<String>, gone: &[String]| list.retain(|item| !gone.contains(item));
        drop(&mut settings.folders, &self.folders);
        drop(&mut settings.skipped, &self.skipped);
        drop(&mut settings.code_folders, &self.code_folders);
        drop(&mut settings.code_skipped, &self.code_skipped);
        for (list, back) in [(&mut settings.skipped, &self.unskipped), (&mut settings.code_skipped, &self.code_unskipped)] {
            for item in back {
                if !list.contains(item) {
                    list.push(item.clone());
                }
            }
        }
        before.folders != settings.folders || before.skipped != settings.skipped
            || before.code_folders != settings.code_folders || before.code_skipped != settings.code_skipped
    }
}

/// How indexing goes, from the index helper's events, for tools (`Status`): what it's doing, how far, and the folders
/// added that it hasn't been through yet.
#[derive(Debug, Default)]
pub struct Progress {
    state: &'static str,
    done: u64,
    total: u64,
    /// Added (with the time), not yet through a pass that started after that.
    pending: Vec<(String, Instant)>,
    /// When the last sync started (a pass's first event).
    synced: Option<Instant>,
}

impl Progress {
    /// A folder was added (by a tool or the add window): its files wait for the next pass.
    pub fn added(&mut self, folder: &str, now: Instant) {
        self.pending.retain(|(path, _)| path != folder);
        self.pending.push((folder.to_string(), now));
    }

    /// It was taken out again (Undo).
    pub fn removed(&mut self, folder: &str) {
        self.pending.retain(|(path, _)| path != folder);
    }

    /// An event of the index helper.
    pub fn event(&mut self, event: &Value, now: Instant) {
        let count = |key: &str| event[key].as_u64().unwrap_or(0);
        match event["event"].as_str().unwrap_or_default() {
            "sync" => {
                self.synced = Some(now);
                if self.state.is_empty() || self.state == "idle" {
                    self.state = "syncing";
                }
            }
            "file" => (self.state, self.done, self.total) = ("indexing", count("done"), count("total")),
            "rest" => self.state = "indexing",
            "transcript" => (self.state, self.done, self.total) = ("transcribing", count("done"), count("total")),
            "waiting" => self.state = "waiting",
            "idle" => {
                self.state = "idle";
                // A folder added before this pass's sync is through; one added since waits for the next.
                if let Some(synced) = self.synced {
                    self.pending.retain(|(_, at)| *at > synced);
                }
            }
            _ => {}
        }
    }

    /// For `Status`: {"state", "done", "total", "pending": [folders still being indexed for the first time]}.
    pub fn json(&self, paused: bool) -> Value {
        let state = if paused { "paused" } else if self.state.is_empty() { "starting" } else { self.state };
        json!({"state": state, "done": self.done, "total": self.total,
               "pending": self.pending.iter().map(|(path, _)| path.clone()).collect::<Vec<_>>()})
    }
}

/// The tools' requests over the session bus: `AddFolder(folder, tool, max_files) → JSON` and `Status() → JSON`.
/// Each answer is a JSON object (`{"ok": true, …}` or `{"ok": false, "message": …}`), so a tool needs no D-Bus types.
#[cfg(target_os = "linux")]
pub struct ToolsBus {
    pub add: std::sync::Arc<dyn Fn(String, String, u32) -> Value + Send + Sync>,
    pub status: std::sync::Arc<dyn Fn() -> Value + Send + Sync>,
}

#[cfg(target_os = "linux")]
#[zbus::interface(name = "com.abdurrahim.DigUp.Tools")]
impl ToolsBus {
    /// Adds `folder` (absolute) for `tool`, if the rules let it: off the bus's thread, as counting and stopping the
    /// index helper take a while.
    async fn add_folder(&self, folder: String, tool: String, max_files: u32) -> String {
        let add = self.add.clone();
        tauri::async_runtime::spawn_blocking(move || add(folder, tool, max_files)).await
            .unwrap_or_else(|error| json!({"ok": false, "message": format!("DigUp couldn't add it: {error}")}))
            .to_string()
    }

    fn status(&self) -> String {
        (self.status)().to_string()
    }
}

/// The bus name tools call: "<identifier>.Tools".
pub fn bus_name(identifier: &str) -> String {
    format!("{identifier}.Tools")
}

pub const OBJECT_PATH: &str = "/com/abdurrahim/DigUp/Tools";
pub const INTERFACE: &str = "com.abdurrahim.DigUp.Tools";

/// Serves `bus` on the session bus under "<identifier>.Tools"; the connection must be kept (dropping it ends it).
#[cfg(target_os = "linux")]
pub fn serve(identifier: &str, bus: ToolsBus) -> zbus::Result<zbus::blocking::Connection> {
    zbus::blocking::connection::Builder::session()?
        .name(bus_name(identifier))?
        .replace_existing_names(false)
        .allow_name_replacements(false)
        .serve_at(OBJECT_PATH, bus)?
        .build()
}

/// `digup-shell --add-folder DIR --from-tool NAME --yes`: asks the running DigUp, as a tool does; the answer.
#[cfg(target_os = "linux")]
pub fn ask_running(identifier: &str, folder: &Path, tool: &str, max_files: u32) -> Value {
    let call = || -> zbus::Result<String> {
        let connection = zbus::blocking::Connection::session()?;
        let reply = connection.call_method(Some(bus_name(identifier).as_str()), OBJECT_PATH, Some(INTERFACE),
                                           "AddFolder", &(folder.display().to_string(), tool, max_files))?;
        reply.body().deserialize::<String>()
    };
    match call() {
        Ok(text) => serde_json::from_str(&text).unwrap_or_else(|_| json!({"ok": false, "message": text})),
        Err(zbus::Error::MethodError(name, _, _)) if name.as_str() == "org.freedesktop.DBus.Error.ServiceUnknown" => {
            json!({"ok": false, "running": false, "message": "DigUp isn't running: start it, then ask again."})
        }
        Err(error) => json!({"ok": false, "message": format!("DigUp didn't answer: {error}")}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn home() -> Option<&'static Path> {
        Some(Path::new("/home/me"))
    }

    #[test]
    fn what_a_tool_may_not_add() {
        let settings = Settings {
            folders: vec!["/home/me/Documents".into()],
            skipped: vec!["/home/me/Documents/Private".into()],
            code_folders: vec!["/home/me/git".into()],
            code_skipped: vec!["/home/me/git/secret".into()],
            ..Settings::default()
        };
        let refused = |path: &str| refused(Path::new(path), home(), &settings).unwrap_or_default();
        assert!(refused("/home/me").contains("whole home folder"));
        assert!(refused("/mnt/data").contains("isn't in your home folder"));
        assert!(refused("/run/media/me/USB").contains("isn't in your home folder"), "drives are for the add window");
        assert!(refused("/home/other/git").contains("isn't in your home folder"));
        assert!(refused("/home/meme/git").contains("isn't in your home folder"), "a folder, not a prefix");
        assert!(refused("/home/me/.ssh").contains("hidden folder"));
        assert!(refused("/home/me/.config/app").contains("hidden folder"));
        assert!(refused("/home/me/git/app/.github").contains("hidden folder"));
        assert!(refused("/home/me/Documents/Private").contains("left out in DigUp's settings"));
        assert!(refused("/home/me/Documents/Private/Taxes").contains("left out"));
        assert!(refused("/home/me/git/secret").contains("left out"));
        for fine in ["/home/me/git/app", "/home/me/Inbox", "/home/me/Documents/Trips", "/home/me/Documents/Privates"] {
            assert_eq!(refused(fine), "", "{fine}");
        }
        assert!(refused("/home/me/x").is_empty());
        assert!(super::refused(Path::new("/home/me/x"), None, &settings).is_some(), "no home: nothing");
    }

    #[test]
    fn tool_names_are_tidied() {
        assert_eq!(tool_name("claude-code"), "claude-code");
        assert_eq!(tool_name("  Cursor\n(1.2) "), "Cursor (1.2)");
        assert_eq!(tool_name("<b>evil</b>\u{202e}"), "bevilb");
        assert_eq!(tool_name("ä".repeat(50).as_str()).chars().count(), 40);
        assert_eq!(tool_name("<>"), "A tool");
        assert_eq!(shown(Path::new("/home/me/git/app"), home()), "~/git/app");
        assert_eq!(shown(Path::new("/data/x"), home()), "/data/x");
    }

    #[test]
    fn counting_stops_at_the_cap_and_leaves_build_folders_out() {
        let root = std::env::temp_dir().join(format!("digup-tools-count-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let make = |path: &str| {
            let file = root.join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, b"x").unwrap();
        };
        for path in ["a.md", "src/b.rs", "src/c.rs", "docs/d.pdf", ".git/objects/1", ".venv/lib/x.py",
                     "node_modules/m/index.js", "target/debug/app", "web/dist/app.js", "src/__pycache__/b.pyc"] {
            make(path);
        }
        let later = Instant::now() + Duration::from_secs(10);
        let counted = count(&root, 100, later);
        assert_eq!((counted.files, counted.over, counted.slow), (4, false, false));
        let shown: Vec<PathBuf> = counted.left_out.iter().map(PathBuf::from).collect();
        assert_eq!(shown, [root.join("target"), root.join("web/dist")]);
        let capped = count(&root, 3, later);
        assert!(capped.over && !capped.slow && capped.files == 4, "stops once past the cap");
        assert!(count(&root, 3, Instant::now() - Duration::from_secs(1)).slow, "out of time: too big");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn undo_takes_back_what_the_add_did() {
        let before = Settings {
            folders: vec!["/home/me/Documents".into()],
            skipped: vec!["/home/me/Documents/Old".into(), "/home/me/Inbox".into()],
            ..Settings::default()
        };
        let mut after = before.clone();
        after.folders.push("/home/me/Sent".into());
        after.skipped.push("/home/me/Sent/build".into());
        after.skipped.retain(|skip| skip != "/home/me/Inbox");
        after.code_folders.push("/home/me/git/app".into());
        after.code_skipped.push("/home/me/git/app/target".into());
        let change = Change::between(&before, &after);
        assert_eq!(change.folders, ["/home/me/Sent"]);
        assert_eq!(change.skipped, ["/home/me/Sent/build"]);
        assert_eq!(change.unskipped, ["/home/me/Inbox"]);
        assert_eq!((change.code_folders.len(), change.code_skipped.len()), (1, 1));
        assert_eq!(Change::between(&before, &before), Change::default());

        // Meanwhile the person added a folder of their own: it stays.
        let mut now = after.clone();
        now.folders.push("/home/me/Music".into());
        assert!(change.undo(&mut now));
        assert_eq!(now.folders, ["/home/me/Documents", "/home/me/Music"]);
        assert_eq!(now.skipped, ["/home/me/Documents/Old", "/home/me/Inbox"]);
        assert!(now.code_folders.is_empty() && now.code_skipped.is_empty());
        assert!(!change.undo(&mut now), "twice: nothing more");
    }

    #[test]
    fn progress_follows_the_index_helper() {
        let start = Instant::now();
        let later = |seconds: u64| start + Duration::from_secs(seconds);
        let mut progress = Progress::default();
        assert_eq!(progress.json(false)["state"], "starting");
        progress.event(&json!({"event": "idle"}), later(0));
        progress.added("/home/me/git/app", later(1));
        // The old helper's last word, before a pass that saw the folder: still pending.
        progress.event(&json!({"event": "idle"}), later(1));
        assert_eq!(progress.json(false)["pending"], json!(["/home/me/git/app"]));
        progress.event(&json!({"event": "sync"}), later(2));
        progress.event(&json!({"event": "file", "done": 40, "total": 300}), later(3));
        let status = progress.json(false);
        assert_eq!((status["state"].as_str(), status["done"].as_u64(), status["total"].as_u64()),
                   (Some("indexing"), Some(40), Some(300)));
        assert_eq!(progress.json(true)["state"], "paused");
        progress.added("/home/me/Sent", later(4));   // during the pass: waits for the next
        progress.event(&json!({"event": "idle"}), later(5));
        assert_eq!(progress.json(false)["pending"], json!(["/home/me/Sent"]));
        assert_eq!(progress.json(false)["state"], "idle");
        progress.removed("/home/me/Sent");
        assert_eq!(progress.json(false)["pending"], json!([]));
    }
}
