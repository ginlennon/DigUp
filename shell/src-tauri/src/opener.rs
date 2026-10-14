//! Opening a result at its place, as the Mac app's `Opener` does (Sources/DigUpApp/Moments.swift): a PDF at the page
//! that matched with a word from it searched for, a recording at its moment, code at its line, each in the file's
//! default app when that app can be told the place, else the plain way (`open_path`, xdg-open). Linux only for now:
//! the default app is found as xdg-open finds it (the file's MIME type → its .desktop file → the program in its Exec
//! line), and each app we know gets the arguments its `--help` lists:
//! - Evince (and GNOME Papers, its successor): `-i <page>` (the page number, 1-based: Evince opens page index − 1)
//!   and `-l <word>` (its search, which also finds the word on that page). `-p` would be the page *label*.
//! - Okular: `-p <page> --find <word>`
//! - Firefox (pdf.js): `file:///…#page=N&search=word`; Chrome and Chromium: `#page=N` (their viewer has no search)
//! - VLC `--start-time=S`, mpv `--start=S`, Celluloid `--mpv-start=S` (mpv's option, passed through)
//! - Totem, which has no start option: it opens the file, and is then told the moment over MPRIS (D-Bus), once its
//!   player is there, has the file and is playing it (checked, and told again if it didn't go there)
//! - VS Code (and its forks) `-g file:line`, Geany `--line=N`, Kate `-l N`, gedit `+N`, Zed and Sublime `file:line`
//!
//! A recording at a moment opens in VLC instead when it's installed and Settings say so (the default: `app_for`).
//!
//! Which app and which arguments are pure functions (`app_for`, `plan`), tested below with made-up .desktop folders.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// What the panel sends of a result (the helper's hit fields, `digup search-service`).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct Hit {
    pub path: String,
    pub kind: String,
    pub segment: String,
    pub loc: Option<f64>,
    pub focus: Option<f64>,
    pub excerpt: Option<String>,
    /// What the index knows of the file (a recording's "duration"…); a Value, so a missing or null one reads too.
    pub info: serde_json::Value,
}

impl Hit {
    /// Where opening should go when it isn't the start, as on the Mac (`ResultRow.jump`): a PDF page after the first,
    /// a moment a second or more in, a line of code.
    pub fn place(&self) -> Option<Place> {
        let loc = self.loc?;
        match (self.kind.as_str(), self.segment.as_str()) {
            ("pdf", "page" | "page_image") if loc >= 2.0 => Some(Place::Page(loc as u32)),
            ("video" | "audio", "frame" | "audio") if loc >= 1.0 => Some(Place::Moment(loc)),
            // Where the name is defined or the query's words are, else where the stretch starts.
            ("code", "lines") => Some(Place::Line(self.focus.unwrap_or(loc).max(1.0) as u32)),
            _ => None,
        }
    }

    /// The recording's length in seconds, when the index knows it.
    fn duration(&self) -> Option<f64> {
        let value = self.info.get("duration")?;
        value.as_f64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Place {
    /// A PDF page, 1-based.
    Page(u32),
    /// Seconds into a recording.
    Moment(f64),
    /// A line of code, 1-based.
    Line(u32),
}

impl Place {
    /// "p. 3", "0:06", "line 12": what the footer and the Open button say after "Open at".
    pub fn text(&self) -> String {
        match *self {
            Place::Page(page) => format!("p. {page}"),
            Place::Moment(seconds) => clock(seconds),
            Place::Line(line) => format!("line {line}"),
        }
    }
}

/// "0:06", "1:02:03", as the panel's badges read.
fn clock(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    if total >= 3600 {
        format!("{}:{:02}:{:02}", total / 3600, total / 60 % 60, total % 60)
    } else {
        format!("{}:{:02}", total / 60, total % 60)
    }
}

/// The apps we can tell a place, known by their program's name.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Viewer {
    Evince,
    Okular,
    Firefox,
    Chromium,
    Vlc,
    Mpv,
    Celluloid,
    Totem,
    VsCode,
    Geany,
    Kate,
    Gedit,
    /// Zed and Sublime Text: `file:line`.
    FileColonLine,
}

impl Viewer {
    pub fn of(program: &str) -> Option<Viewer> {
        let name = Path::new(program).file_name()?.to_str()?;
        Some(match name {
            "evince" | "papers" => Viewer::Evince,
            "okular" => Viewer::Okular,
            "firefox" | "firefox-esr" => Viewer::Firefox,
            "google-chrome" | "google-chrome-stable" | "chromium" | "chromium-browser" => Viewer::Chromium,
            "vlc" => Viewer::Vlc,
            "mpv" => Viewer::Mpv,
            "celluloid" => Viewer::Celluloid,
            "totem" => Viewer::Totem,
            "code" | "code-insiders" | "codium" | "cursor" | "windsurf" => Viewer::VsCode,
            "geany" => Viewer::Geany,
            "kate" => Viewer::Kate,
            "gedit" => Viewer::Gedit,
            "zed" | "zeditor" | "subl" => Viewer::FileColonLine,
            _ => return None,
        })
    }

    /// Whether it can be told this kind of place.
    fn goes_to(&self, place: Place) -> bool {
        use Viewer::*;
        match place {
            Place::Page(_) => matches!(self, Evince | Okular | Firefox | Chromium),
            Place::Moment(_) => matches!(self, Vlc | Mpv | Celluloid | Totem),
            Place::Line(_) => matches!(self, VsCode | Geany | Kate | Gedit | FileColonLine),
        }
    }
}

/// A file's default app: its .desktop id and the program its Exec line runs.
#[derive(Clone, Debug, PartialEq)]
pub struct App {
    pub id: String,
    pub program: String,
}

/// How a result opens.
#[derive(Debug, PartialEq)]
pub enum Plan {
    /// The default app, the plain way (xdg-open).
    Plain,
    /// This command line goes to the place.
    Run { argv: Vec<String>, place: Place },
    /// This command line opens the recording; then its MPRIS player is told the moment.
    RunThenSeek { argv: Vec<String>, bus: String, seconds: f64, duration: Option<f64> },
}

impl Plan {
    /// What ↩ does, for the footer and the Open button: "Open at p. 3", "Open at 0:06", else "Open".
    pub fn title(&self) -> String {
        match self {
            Plan::Plain => "Open".to_string(),
            Plan::Run { place, .. } => format!("Open at {}", place.text()),
            Plan::RunThenSeek { seconds, .. } => format!("Open at {}", clock(*seconds)),
        }
    }
}

/// How `hit` opens in `app` (its default app, if there is one), searching for a word of `query` on a PDF's page.
pub fn plan(hit: &Hit, query: &str, app: Option<&App>) -> Plan {
    let (Some(place), Some(app)) = (hit.place(), app) else { return Plan::Plain };
    let Some(viewer) = Viewer::of(&app.program).filter(|viewer| viewer.goes_to(place)) else { return Plan::Plain };
    let program = app.program.clone();
    let file = hit.path.clone();
    // Whole seconds: the moment is that coarse anyway, and a decimal point is read by locale in some players.
    let whole = |seconds: f64| format!("{}", seconds.max(0.0) as u64);
    let argv: Vec<String> = match (viewer, place) {
        (Viewer::Evince | Viewer::Okular, Place::Page(page)) => {
            let mut argv = if viewer == Viewer::Evince {
                vec![program, "-i".into(), page.to_string()]
            } else {
                vec![program, "-p".into(), page.to_string()]
            };
            if let Some(word) = search_word(hit.excerpt.as_deref().unwrap_or_default(), query) {
                argv.extend([if viewer == Viewer::Evince { "-l" } else { "--find" }.to_string(), word]);
            }
            argv.push(file);
            argv
        }
        (Viewer::Firefox | Viewer::Chromium, Place::Page(page)) => {
            let Ok(mut url) = tauri::Url::from_file_path(&file) else { return Plan::Plain };
            let mut fragment = format!("page={page}");
            if viewer == Viewer::Firefox {
                if let Some(word) = search_word(hit.excerpt.as_deref().unwrap_or_default(), query) {
                    fragment += &format!("&search={}", escaped(&word));
                }
            }
            url.set_fragment(Some(&fragment));
            vec![program, url.to_string()]
        }
        (Viewer::Vlc, Place::Moment(seconds)) => vec![program, format!("--start-time={}", whole(seconds)), file],
        (Viewer::Mpv, Place::Moment(seconds)) => vec![program, format!("--start={}", whole(seconds)), file],
        (Viewer::Celluloid, Place::Moment(seconds)) => vec![program, format!("--mpv-start={}", whole(seconds)), file],
        (Viewer::Totem, Place::Moment(seconds)) => {
            return Plan::RunThenSeek {
                argv: vec![program, file],
                bus: "org.mpris.MediaPlayer2.totem".into(),
                seconds,
                duration: hit.duration(),
            }
        }
        (Viewer::VsCode, Place::Line(line)) => vec![program, "-g".into(), format!("{file}:{line}")],
        (Viewer::Geany, Place::Line(line)) => vec![program, format!("--line={line}"), file],
        (Viewer::Kate, Place::Line(line)) => vec![program, "-l".into(), line.to_string(), file],
        (Viewer::Gedit, Place::Line(line)) => vec![program, format!("+{line}"), file],
        (Viewer::FileColonLine, Place::Line(line)) => vec![program, format!("{file}:{line}")],
        _ => return Plan::Plain,
    };
    Plan::Run { argv, place }
}

/// The word to search for on a PDF's page, as the Mac's `Landmark` picks one: a word that's on that page, so the
/// viewer's search lands there. We don't read the PDF here, so "on the page" means in the hit's excerpt (the text the
/// index has of that page): the words keyword search found there (marked « »), else the first word of the query
/// that's in it, spelled as the page spells it. Words under three letters find too much. None: just the page.
pub fn search_word(excerpt: &str, query: &str) -> Option<String> {
    let mut rest = excerpt;
    while let (Some(open), Some(close)) = (rest.find('«'), rest.find('»')) {
        if close < open {
            rest = &rest[close + '»'.len_utf8()..];
            continue;
        }
        let word = rest[open + '«'.len_utf8()..close].trim();
        if word.chars().count() >= 3 {
            return Some(word.to_string());
        }
        rest = &rest[close + '»'.len_utf8()..];
    }
    let words: Vec<&str> = excerpt.split(|c: char| !c.is_alphanumeric()).filter(|word| !word.is_empty()).collect();
    for wanted in query.split(|c: char| !c.is_alphanumeric()).filter(|word| word.chars().count() >= 3) {
        if let Some(found) = words.iter().find(|word| word.to_lowercase() == wanted.to_lowercase()) {
            return Some(found.to_string());
        }
    }
    None
}

/// Percent-encoded for a URL's fragment (letters, digits and -._~ stay).
fn escaped(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

// MARK: The default app

/// The folders .desktop files are in, first wins (the XDG base directory spec): $XDG_DATA_HOME (~/.local/share),
/// then $XDG_DATA_DIRS (/usr/local/share:/usr/share), each with "applications".
pub fn application_folders(data_home: Option<&str>, data_dirs: Option<&str>, home: Option<&str>) -> Vec<PathBuf> {
    let mut folders = Vec::new();
    match data_home.filter(|value| !value.is_empty()) {
        Some(home_data) => folders.push(PathBuf::from(home_data)),
        None => folders.extend(home.map(|home| Path::new(home).join(".local/share"))),
    }
    let dirs = data_dirs.filter(|value| !value.is_empty()).unwrap_or("/usr/local/share:/usr/share");
    folders.extend(dirs.split(':').filter(|dir| !dir.is_empty()).map(PathBuf::from));
    folders.into_iter().map(|folder| folder.join("applications")).collect()
}

/// The .desktop file with this id: "org.gnome.Evince.desktop" is applications/org.gnome.Evince.desktop, and an id with
/// a dash may also be in a subfolder ("kde-okular.desktop" → applications/kde/okular.desktop).
pub fn desktop_file(id: &str, folders: &[PathBuf]) -> Option<PathBuf> {
    let nested = id.split_once('-').map(|(folder, rest)| Path::new(folder).join(rest));
    folders.iter().find_map(|folder| {
        let direct = folder.join(id);
        if direct.is_file() {
            return Some(direct);
        }
        nested.as_ref().map(|nested| folder.join(nested)).filter(|path| path.is_file())
    })
}

/// The program a .desktop file's Exec line runs (its [Desktop Entry]'s, not an action's): "evince" of
/// `Exec=evince %U`, "/usr/bin/vlc" of `Exec=/usr/bin/vlc --started-from-file %U`, the program after `env A=b`.
pub fn exec_program(desktop: &str) -> Option<String> {
    let mut in_entry = false;
    for line in desktop.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some(exec) = line.strip_prefix("Exec").map(str::trim_start).and_then(|rest| rest.strip_prefix('=')) else {
            continue;
        };
        let words = exec_words(exec.trim());
        let setting = |word: &&String| *word == "env" || (word.contains('=') && !word.starts_with('/'));
        return words.iter().find(|word| !setting(word)).cloned();
    }
    None
}

/// An Exec line's words: split at spaces, with "double quoted" ones kept whole (\" \\ \` \$ escaped inside).
fn exec_words(exec: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let (mut quoted, mut started) = (false, false);
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            '\\' if quoted => word.extend(chars.next()),
            ' ' | '\t' if !quoted => {
                if started || !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
                started = false;
            }
            c => word.push(c),
        }
    }
    if started || !word.is_empty() {
        words.push(word);
    }
    words
}

/// A command's first line of output, if it ran and printed one.
fn first_line(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).env("LC_ALL", "C").stdin(Stdio::null()).stderr(Stdio::null())
        .output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().next().map(str::trim).filter(|line| !line.is_empty()).map(String::from)
}

/// The .desktop id of the default app for a MIME type: xdg-mime's answer, else gio's (GNOME's, which also knows the
/// type's aliases: a WAV file is audio/vnd.wave, whose default xdg-mime leaves empty and gio answers). xdg-open on
/// GNOME opens with gio, so that's the app a plain open would use too.
fn default_desktop_id(mime: &str) -> Option<String> {
    if let Some(id) = first_line("xdg-mime", &["query", "default", mime]) {
        return Some(id);
    }
    // "Default application for “audio/vnd.wave”: org.gnome.Totem.desktop" (or "No default applications for …").
    let line = first_line("gio", &["mime", mime])?;
    let id = line.rsplit(": ").next()?.trim();
    id.ends_with(".desktop").then(|| id.to_string())
}

/// The default apps of files, by extension, asked again after half a minute (one may have been changed meanwhile).
/// The footer asks on every move of the selection, and each answer is two small processes.
pub struct Apps {
    /// By extension, and VLC under "" (no file's extension).
    known: Mutex<HashMap<String, (Instant, Option<App>)>>,
}

impl Apps {
    pub fn new() -> Apps {
        Apps { known: Mutex::new(HashMap::new()) }
    }

    pub fn for_file(&self, path: &str) -> Option<App> {
        let extension = Path::new(path).extension().and_then(|ext| ext.to_str()).unwrap_or_default().to_lowercase();
        self.remembered(extension, || default_app(path))
    }

    /// The app `hit` opens in (`app_for`), VLC preferred for recordings at a moment when `prefer_vlc`.
    pub fn for_hit(&self, hit: &Hit, prefer_vlc: bool) -> Option<App> {
        app_for(hit, prefer_vlc, || self.vlc(), || self.for_file(&hit.path))
    }

    /// VLC, when it's installed (asked again after half a minute too: it may have been installed meanwhile).
    pub fn vlc(&self) -> Option<App> {
        self.remembered(String::new(), installed_vlc)
    }

    fn remembered(&self, key: String, find: impl FnOnce() -> Option<App>) -> Option<App> {
        if let Some((when, app)) = self.known.lock().unwrap().get(&key) {
            if when.elapsed() < Duration::from_secs(30) {
                return app.clone();
            }
        }
        let app = find();
        self.known.lock().unwrap().insert(key, (Instant::now(), app.clone()));
        app
    }
}

/// The app a result opens in. A recording with a moment goes to VLC when the person would rather (Settings, "Open
/// recordings at the moment in") and it's installed: a VLC started without its .desktop file's --started-from-file is
/// a new instance, which starts at `--start-time` (one-instance-when-started-from-file would hand the file to a
/// running VLC, which ignores it). Everything else, and recordings when VLC isn't there, open in the default app.
pub fn app_for(hit: &Hit, prefer_vlc: bool, vlc: impl FnOnce() -> Option<App>,
               default: impl FnOnce() -> Option<App>) -> Option<App> {
    if prefer_vlc && matches!(hit.place(), Some(Place::Moment(_))) {
        if let Some(vlc) = vlc() {
            return Some(vlc);
        }
    }
    default()
}

/// `name` as the shell would find it on $PATH: the first executable file of that name.
fn on_path(name: &str, path: Option<&str>) -> Option<PathBuf> {
    std::env::split_paths(path?).map(|folder| folder.join(name)).find(|file| is_program(file))
}

fn is_program(file: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.metadata().is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    file.is_file()
}

/// VLC, if it's installed (Linux): `vlc` on $PATH, else the program of its .desktop file when that's VLC itself and is
/// there. A Flatpak's Exec line runs `flatpak`, which can't be given the start time like this: not counted.
fn installed_vlc() -> Option<App> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    let env = |key: &str| std::env::var(key).ok();
    if let Some(program) = on_path("vlc", env("PATH").as_deref()) {
        return Some(App { id: "vlc.desktop".into(), program: program.display().to_string() });
    }
    let folders = application_folders(env("XDG_DATA_HOME").as_deref(), env("XDG_DATA_DIRS").as_deref(),
                                      env("HOME").as_deref());
    ["vlc.desktop", "org.videolan.VLC.desktop"].iter().find_map(|id| {
        let program = exec_program(&std::fs::read_to_string(desktop_file(id, &folders)?).ok()?)?;
        let there = is_program(Path::new(&program)) || on_path(&program, env("PATH").as_deref()).is_some();
        (Viewer::of(&program) == Some(Viewer::Vlc) && there).then(|| App { id: id.to_string(), program })
    })
}

/// The file's default app, as xdg-open would choose it (Linux; elsewhere none: results open the plain way).
fn default_app(path: &str) -> Option<App> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    let mime = first_line("xdg-mime", &["query", "filetype", path])?;
    let id = default_desktop_id(&mime)?;
    let env = |key: &str| std::env::var(key).ok();
    let folders = application_folders(env("XDG_DATA_HOME").as_deref(), env("XDG_DATA_DIRS").as_deref(),
                                      env("HOME").as_deref());
    let desktop = std::fs::read_to_string(desktop_file(&id, &folders)?).ok()?;
    Some(App { id, program: exec_program(&desktop)? })
}

// MARK: Opening

/// Starts the app on its own: in its own session (closing a terminal that ran a dev shell doesn't close it), and
/// waited for on a thread so it never lingers as a zombie.
fn launch(argv: &[String]) -> Result<(), String> {
    let (program, args) = argv.split_first().ok_or("nothing to run")?;
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: setsid() only detaches the new process from our session, between fork and exec.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    let mut child = command.spawn().map_err(|error| format!("can't start {program}: {error}"))?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// Runs the plan (not `Plan::Plain`: that's the caller's open_path). Totem's moment is set on a thread of its own.
pub fn run(plan: &Plan) -> Result<(), String> {
    match plan {
        Plan::Plain => Err("opens the plain way".into()),
        Plan::Run { argv, .. } => launch(argv),
        Plan::RunThenSeek { argv, bus, seconds, duration } => {
            launch(argv)?;
            let (bus, seconds, duration) = (bus.clone(), *seconds, *duration);
            std::thread::spawn(move || seek_when_ready(&bus, seconds, duration));
            Ok(())
        }
    }
}

/// What an MPRIS player says about itself (`gdbus call … Properties.GetAll org.mpris.MediaPlayer2.Player`, in GVariant
/// text): whether it can seek now, the track's length (µs) and id, and where it is (µs).
#[derive(Debug, Default, PartialEq)]
pub struct Player {
    pub can_seek: bool,
    pub length: Option<i64>,
    pub track: Option<String>,
    pub position: Option<i64>,
}

/// The number after `<` (and a type: "int64 ", "@x "), as GVariant text writes one: `<int64 18000000>`.
fn variant_number(rest: &str) -> Option<i64> {
    let rest = rest.trim_start_matches("int64 ").trim_start_matches("uint64 ").trim_start_matches("@x ");
    let digits = rest.strip_prefix('-').unwrap_or(rest);
    let end = rest.len() - digits.len() + digits.chars().take_while(char::is_ascii_digit).count();
    rest[..end].parse().ok()
}

pub fn parse_player(text: &str) -> Player {
    let after = |key: &str| text.find(key).map(|at| &text[at + key.len()..]);
    let track = after("'mpris:trackid': <").and_then(|rest| {
        let rest = rest.strip_prefix("objectpath ").unwrap_or(rest).strip_prefix('\'')?;
        rest.find('\'').map(|end| rest[..end].to_string())
    });
    Player {
        can_seek: text.contains("'CanSeek': <true>"),
        length: after("'mpris:length': <").and_then(variant_number),
        track,
        position: after("'Position': <").and_then(variant_number),
    }
}

/// The position in `Properties.Get … Position`'s answer: `(<int64 2200000>,)`.
pub fn parse_position(text: &str) -> Option<i64> {
    variant_number(&text[text.find('<')? + 1..])
}

/// Whether to tell the player the moment now: it can seek, it has our recording (its length is the one the index
/// knows; Totem's MPRIS doesn't say the file), and it has started playing it. Totem says "Playing" with the right
/// length at once, while its pipeline is still starting, and a position set then is lost (seen with Totem 43 on
/// GNOME 46: SetPosition answered fine and it stayed at the start); once the position moves, it takes one. A recording
/// whose length reads differently there, or that doesn't start by itself, gets the moment after a few seconds anyway.
pub fn ready_to_seek(player: &Player, duration: Option<f64>, waited: Duration) -> bool {
    if !player.can_seek {
        return false;
    }
    let ours = match (player.length, duration) {
        (Some(length), Some(duration)) => (length as f64 / 1e6 - duration).abs() < 1.5,
        _ => waited >= Duration::from_secs(1),
    };
    let playing = player.position.is_some_and(|position| position > 0);
    (ours || waited >= Duration::from_secs(4)) && (playing || waited >= Duration::from_secs(6))
}

/// The player went there: a little after the moment (it plays on) or right at it, not back at the start.
pub fn landed(position: Option<i64>, seconds: f64) -> bool {
    position.is_some_and(|position| (position as f64 / 1e6 - seconds).abs() < 1.0)
}

/// How each try tells the player the moment: SetPosition, and then once more; then, should it still not be there,
/// Pause, Seek back past the start, Seek forward to the moment, Play (which Totem takes when SetPosition doesn't).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Telling {
    SetPosition,
    SeekFromStart,
}

pub const TRIES: [Telling; 3] = [Telling::SetPosition, Telling::SetPosition, Telling::SeekFromStart];

const MPRIS_PATH: &str = "/org/mpris/MediaPlayer2";

/// A method of the player on `bus` (gdbus rather than a D-Bus crate: a few calls don't earn a dependency). Its answer
/// in GVariant text, if it answered.
fn call(bus: &str, method: &str, args: &[String]) -> Option<String> {
    let output = Command::new("gdbus")
        .args(["call", "--session", "--dest", bus, "--object-path", MPRIS_PATH, "--method", method])
        .args(args)
        .stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn tell(bus: &str, how: Telling, track: &str, seconds: f64) {
    let player = "org.mpris.MediaPlayer2.Player";
    let micros = (seconds * 1e6) as i64;
    match how {
        Telling::SetPosition => {
            call(bus, &format!("{player}.SetPosition"), &[format!("objectpath '{track}'"), format!("int64 {micros}")]);
        }
        Telling::SeekFromStart => {
            call(bus, &format!("{player}.Pause"), &[]);
            call(bus, &format!("{player}.Seek"), &["int64 -1000000000000".to_string()]);
            call(bus, &format!("{player}.Seek"), &[format!("int64 {micros}")]);
            call(bus, &format!("{player}.Play"), &[]);
        }
    }
}

/// Waits (up to ten seconds) for the player on `bus` to be playing the recording, then sets its position, and checks
/// it went there (`TRIES`).
fn seek_when_ready(bus: &str, seconds: f64, duration: Option<f64>) {
    let started = Instant::now();
    let mut ready = None;
    while ready.is_none() && started.elapsed() < Duration::from_secs(10) {
        std::thread::sleep(Duration::from_millis(200));
        // No answer: not there yet (the player is starting), ask again.
        let Some(text) = call(bus, "org.freedesktop.DBus.Properties.GetAll", &["org.mpris.MediaPlayer2.Player".into()])
        else { continue };
        let player = parse_player(&text);
        if ready_to_seek(&player, duration, started.elapsed()) {
            ready = Some(player);
        }
    }
    let Some(player) = ready else {
        log_error!("digup-shell: {bus} didn't come up to be told the moment");
        return;
    };
    let track = player.track.unwrap_or_else(|| "/org/mpris/MediaPlayer2/TrackList/NoTrack".into());
    let mut position = None;
    for (number, how) in TRIES.iter().enumerate() {
        tell(bus, *how, &track, seconds);
        std::thread::sleep(Duration::from_millis(300));
        position = call(bus, "org.freedesktop.DBus.Properties.Get",
                        &["org.mpris.MediaPlayer2.Player".into(), "Position".into()])
            .as_deref().and_then(parse_position);
        if landed(position, seconds) {
            if cfg!(debug_assertions) {
                log!("open: {bus} at {seconds:.1} s after {} tries ({how:?}), {:.1} s after it started",
                     number + 1, started.elapsed().as_secs_f64());
            }
            return;
        }
    }
    log_error!("digup-shell: {bus} didn't go to {seconds:.1} s (at {position:?} µs after {} tries)", TRIES.len());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit(kind: &str, segment: &str, loc: f64) -> Hit {
        Hit { path: "/home/me/Docs/Lease 2026.pdf".into(), kind: kind.into(), segment: segment.into(), loc: Some(loc),
              ..Hit::default() }
    }

    fn app(program: &str) -> App {
        App { id: "x.desktop".into(), program: program.into() }
    }

    fn argv(plan: Plan) -> Vec<String> {
        match plan {
            Plan::Run { argv, .. } | Plan::RunThenSeek { argv, .. } => argv,
            Plan::Plain => panic!("plain"),
        }
    }

    #[test]
    fn places_are_where_the_mac_jumps() {
        assert_eq!(hit("pdf", "page", 3.0).place(), Some(Place::Page(3)));
        assert_eq!(hit("pdf", "page_image", 1.0).place(), None, "page 1 opens there anyway");
        assert_eq!(hit("pdf", "chunk", 3.0).place(), None);
        assert_eq!(hit("video", "frame", 6.4).place(), Some(Place::Moment(6.4)));
        assert_eq!(hit("audio", "audio", 0.5).place(), None, "under a second is the start");
        let mut code = hit("code", "lines", 12.0);
        code.focus = Some(15.0);
        assert_eq!(code.place(), Some(Place::Line(15)));
    }

    #[test]
    fn pdf_pages_in_each_viewer() {
        let mut page = hit("pdf", "page", 3.0);
        page.excerpt = Some("…the «pets» clause of the lease…".into());
        assert_eq!(argv(plan(&page, "pets lease", Some(&app("evince")))),
                   ["evince", "-i", "3", "-l", "pets", "/home/me/Docs/Lease 2026.pdf"]);
        assert_eq!(argv(plan(&page, "pets", Some(&app("/usr/bin/okular")))),
                   ["/usr/bin/okular", "-p", "3", "--find", "pets", "/home/me/Docs/Lease 2026.pdf"]);
        assert_eq!(argv(plan(&page, "pets", Some(&app("firefox")))),
                   ["firefox", "file:///home/me/Docs/Lease%202026.pdf#page=3&search=pets"]);
        assert_eq!(argv(plan(&page, "pets", Some(&app("/usr/bin/google-chrome-stable")))),
                   ["/usr/bin/google-chrome-stable", "file:///home/me/Docs/Lease%202026.pdf#page=3"]);
        assert_eq!(plan(&page, "pets", Some(&app("evince"))).title(), "Open at p. 3");
        // No word of the query on the page: just the page.
        page.excerpt = Some("nothing alike".into());
        assert_eq!(argv(plan(&page, "zebra", Some(&app("evince")))),
                   ["evince", "-i", "3", "/home/me/Docs/Lease 2026.pdf"]);
        // An app that can't be told a page, or none: the plain way.
        assert_eq!(plan(&page, "pets", Some(&app("xreader"))), Plan::Plain);
        assert_eq!(plan(&page, "pets", None), Plan::Plain);
        assert_eq!(plan(&hit("pdf", "page", 1.0), "pets", Some(&app("evince"))).title(), "Open");
    }

    #[test]
    fn moments_in_each_player() {
        let mut moment = hit("video", "frame", 6.7);
        moment.path = "/v/zebra.mp4".into();
        assert_eq!(argv(plan(&moment, "", Some(&app("/usr/bin/vlc")))), ["/usr/bin/vlc", "--start-time=6", "/v/zebra.mp4"]);
        assert_eq!(argv(plan(&moment, "", Some(&app("mpv")))), ["mpv", "--start=6", "/v/zebra.mp4"]);
        assert_eq!(argv(plan(&moment, "", Some(&app("celluloid")))), ["celluloid", "--mpv-start=6", "/v/zebra.mp4"]);
        moment.info = serde_json::json!({"duration": 18.0});
        let totem = plan(&moment, "", Some(&app("totem")));
        assert_eq!(totem.title(), "Open at 0:06");
        assert_eq!(totem, Plan::RunThenSeek { argv: vec!["totem".into(), "/v/zebra.mp4".into()],
                                              bus: "org.mpris.MediaPlayer2.totem".into(), seconds: 6.7,
                                              duration: Some(18.0) });
        assert_eq!(plan(&moment, "", Some(&app("audacious"))), Plan::Plain);
        assert_eq!(plan(&moment, "", Some(&app("evince"))), Plan::Plain, "a PDF viewer can't go to a moment");
    }

    #[test]
    fn recordings_at_a_moment_go_to_vlc_when_chosen() {
        let vlc = || Some(app("/usr/bin/vlc"));
        let totem = || Some(app("totem"));
        let mut moment = hit("video", "frame", 6.7);
        moment.path = "/v/zebra.mp4".into();
        let opened = |hit: &Hit, prefer_vlc: bool, vlc: Option<App>| {
            app_for(hit, prefer_vlc, || vlc, totem).map(|app| app.program)
        };
        assert_eq!(opened(&moment, true, vlc()).as_deref(), Some("/usr/bin/vlc"), "even when Totem is the default");
        assert_eq!(opened(&moment, true, None).as_deref(), Some("totem"), "no VLC: the default app");
        assert_eq!(opened(&moment, false, vlc()).as_deref(), Some("totem"), "the default app was chosen");
        let start = hit("video", "frame", 0.4);
        assert_eq!(opened(&start, true, vlc()).as_deref(), Some("totem"), "no moment: the default app");
        let page = hit("pdf", "page", 3.0);
        assert_eq!(opened(&page, true, vlc()).as_deref(), Some("totem"), "not a recording");
        let chosen = app_for(&moment, true, vlc, totem);
        let plan = plan(&moment, "", chosen.as_ref());
        assert_eq!(plan.title(), "Open at 0:06");
        assert_eq!(argv(plan), ["/usr/bin/vlc", "--start-time=6", "/v/zebra.mp4"], "no --started-from-file");
    }

    #[test]
    fn programs_on_the_path() {
        let root = std::env::temp_dir().join(format!("digup-path-test-{}", std::process::id()));
        let (bin, other) = (root.join("bin"), root.join("other"));
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(bin.join("vlc"), "#!/bin/sh\n").unwrap();
        std::fs::write(other.join("vlc"), "not a program").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(bin.join("vlc"), std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = std::env::join_paths([&other, &bin]).unwrap();
        assert_eq!(on_path("vlc", path.to_str()), Some(bin.join("vlc")));
        assert_eq!(on_path("mpv", path.to_str()), None);
        assert_eq!(on_path("vlc", None), None);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn code_at_its_line() {
        let mut code = hit("code", "lines", 12.0);
        code.path = "/src/main.rs".into();
        assert_eq!(argv(plan(&code, "", Some(&app("/usr/share/code/code")))), ["/usr/share/code/code", "-g", "/src/main.rs:12"]);
        assert_eq!(argv(plan(&code, "", Some(&app("geany")))), ["geany", "--line=12", "/src/main.rs"]);
        assert_eq!(plan(&code, "", Some(&app("geany"))).title(), "Open at line 12");
        assert_eq!(plan(&code, "", Some(&app("gnome-text-editor"))), Plan::Plain);
    }

    #[test]
    fn the_word_searched_is_on_the_page() {
        assert_eq!(search_word("a «to» b «Pets» c", "pets").as_deref(), Some("Pets"), "short words find too much");
        assert_eq!(search_word("Die Kündigungsfrist beträgt", "kündigungsfrist miete").as_deref(), Some("Kündigungsfrist"));
        assert_eq!(search_word("the zebra", "a zebra").as_deref(), Some("zebra"));
        assert_eq!(search_word("the zebra", "lion"), None);
        assert_eq!(search_word("", "lion"), None);
    }

    #[test]
    fn exec_lines() {
        assert_eq!(exec_program("[Desktop Entry]\nName=Evince\nExec=evince %U\n\n[Desktop Action new-window]\nExec=evince --new-window\n").as_deref(),
                   Some("evince"));
        assert_eq!(exec_program("[Desktop Action x]\nExec=nope\n[Desktop Entry]\nExec=/usr/bin/vlc --started-from-file %U").as_deref(),
                   Some("/usr/bin/vlc"));
        assert_eq!(exec_program("[Desktop Entry]\nExec=env BAMF_DESKTOP_FILE_HINT=/x.desktop /snap/bin/firefox %u").as_deref(),
                   Some("/snap/bin/firefox"));
        assert_eq!(exec_program("[Desktop Entry]\nExec=\"/opt/My Viewer/viewer\" %f").as_deref(), Some("/opt/My Viewer/viewer"));
        assert_eq!(exec_program("[Desktop Entry]\nTryExec=okular\nExec = okular %U").as_deref(), Some("okular"));
        assert_eq!(exec_program("[Desktop Entry]\nName=No exec"), None);
    }

    #[test]
    fn desktop_files_in_xdg_folders() {
        let root = std::env::temp_dir().join(format!("digup-opener-test-{}", std::process::id()));
        let (home, system) = (root.join("home/.local/share"), root.join("usr/share"));
        std::fs::create_dir_all(home.join("applications")).unwrap();
        std::fs::create_dir_all(system.join("applications/kde")).unwrap();
        std::fs::write(system.join("applications/org.gnome.Evince.desktop"), "[Desktop Entry]\nExec=evince %U\n").unwrap();
        std::fs::write(home.join("applications/org.gnome.Evince.desktop"), "[Desktop Entry]\nExec=papers %U\n").unwrap();
        std::fs::write(system.join("applications/kde/okular.desktop"), "[Desktop Entry]\nExec=okular %U\n").unwrap();
        let folders = application_folders(None, Some(system.to_str().unwrap()),
                                          Some(root.join("home").to_str().unwrap()));
        assert_eq!(folders[0], home.join("applications"));
        // The person's own copy comes first.
        let evince = desktop_file("org.gnome.Evince.desktop", &folders).unwrap();
        assert_eq!(exec_program(&std::fs::read_to_string(evince).unwrap()).as_deref(), Some("papers"));
        let okular = desktop_file("kde-okular.desktop", &folders).unwrap();
        assert_eq!(okular, system.join("applications/kde/okular.desktop"));
        assert_eq!(desktop_file("vlc.desktop", &folders), None);
        assert_eq!(application_folders(Some("/d"), None, Some("/h")),
                   [PathBuf::from("/d/applications"), "/usr/local/share/applications".into(), "/usr/share/applications".into()]);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mpris_players() {
        let totem = "({'CanQuit': <true>, 'Metadata': <{'mpris:trackid': <objectpath '/org/mpris/MediaPlayer2/TrackList/NoTrack'>, \
                     'mpris:length': <int64 18000000>, 'xesam:title': <'zebra'>}>, 'CanSeek': <true>, 'Position': <int64 0>},)";
        let player = parse_player(totem);
        assert_eq!(player, Player { can_seek: true, length: Some(18_000_000),
                                    track: Some("/org/mpris/MediaPlayer2/TrackList/NoTrack".into()), position: Some(0) });
        assert!(!ready_to_seek(&player, Some(18.2), Duration::from_millis(250)), "it hasn't started playing");
        assert!(ready_to_seek(&player, Some(18.2), Duration::from_secs(6)), "one that doesn't start gets it anyway");
        let playing = Player { position: Some(250_000), ..player };
        assert!(ready_to_seek(&playing, Some(18.2), Duration::from_millis(600)));
        assert!(!ready_to_seek(&playing, Some(240.0), Duration::from_secs(2)), "still the recording it had before");
        assert!(ready_to_seek(&playing, Some(240.0), Duration::from_secs(4)));
        let starting = parse_player("({'CanSeek': <false>, 'Metadata': <@a{sv} {}>},)");
        assert_eq!(starting, Player::default());
        assert!(!ready_to_seek(&starting, None, Duration::from_secs(7)));
    }

    #[test]
    fn totem_just_after_launch() {
        // What Totem 43 says at once (GNOME 46): playing, the right length, no track id, at the start.
        let totem = "({'CanQuit': <true>, 'PlaybackStatus': <'Playing'>, 'Metadata': <{'mpris:length': <int64 18083333>, \
                     'xesam:trackNumber': <0>}>, 'CanSeek': <true>, 'Position': <int64 0>, 'Rate': <1.0>},)";
        let player = parse_player(totem);
        assert_eq!((player.track, player.length, player.position), (None, Some(18_083_333), Some(0)));
        assert!(!ready_to_seek(&parse_player(totem), Some(18.08), Duration::from_millis(400)));
        let later = totem.replace("'Position': <int64 0>", "'Position': <int64 1450000>");
        assert!(ready_to_seek(&parse_player(&later), Some(18.08), Duration::from_millis(1600)));
    }

    #[test]
    fn where_the_player_went() {
        assert_eq!(parse_position("(<int64 2200000>,)"), Some(2_200_000));
        assert_eq!(parse_position("(<@x -5>,)"), Some(-5));
        assert_eq!(parse_position("Error: no such object"), None);
        assert!(landed(Some(6_800_000), 6.5), "it plays on after the seek");
        assert!(!landed(Some(300_000), 6.5), "still at the start: told again");
        assert!(!landed(None, 6.5));
        assert_eq!(TRIES, [Telling::SetPosition, Telling::SetPosition, Telling::SeekFromStart]);
    }
}
