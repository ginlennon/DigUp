//! What the shell is told at launch: where the helper, the index and the model are, and, in dev runs, folders and a
//! hotkey that stand in for the settings'; and what to do (`Command`: `--toggle`, `--pause`, `--add-folder DIR`…),
//! which a second launch hands to the running DigUp, so shortcuts, scripts and other apps can control it.

use std::path::PathBuf;

/// The panel's hotkey unless told otherwise: ⇧⌘Space on a Mac (the Mac app's), Ctrl+Shift+Space on Windows,
/// Ctrl+Alt+Space on Linux (GNOME's Shift+Super+Space switches input sources, and Ctrl+Shift+Space is taken in apps).
#[cfg(not(target_os = "linux"))]
pub const DEFAULT_HOTKEY: &str = "CommandOrControl+Shift+Space";
#[cfg(target_os = "linux")]
pub const DEFAULT_HOTKEY: &str = "Control+Alt+Space";

pub struct Options {
    /// DigUp's helper, `digup` (default: beside this program, where the installers put it).
    pub helper: PathBuf,
    /// The index folder. None: the helper's own default (%LOCALAPPDATA%\DigUp\index on Windows,
    /// ~/.local/share/digup/index on Linux).
    pub index: Option<PathBuf>,
    /// Where the model files are (DIGUP_MODELS for the helpers); None: the helper looks where it always does.
    pub models: Option<PathBuf>,
    /// The folders to search and keep indexed, instead of the settings' (dev runs; setup is then skipped).
    pub roots: Vec<PathBuf>,
    /// The hotkey, instead of the settings'.
    pub hotkey: Option<String>,
    /// The settings file, instead of the one in the app's config folder (a fresh first launch in tests).
    pub settings: Option<PathBuf>,
    /// What to do: what the running DigUp is asked to do, or this one once it's up.
    pub command: Option<Command>,
    /// The folders setup offers, instead of the usual ones (Documents, Pictures…): dev runs never offer real folders.
    pub offered: Option<Vec<PathBuf>>,
    /// Debug runs: setup clicks through by itself (all offered folders, the default hotkey).
    pub debug_setup: bool,
    /// Debug runs: the panel types this query in when it loads and reports what it showed (`debug_report`), hidden
    /// unless `debug_show`: a panel on screen takes the keyboard.
    pub debug_query: Option<String>,
    /// Debug runs: the filter the panel types in under the query (alone, a search by the filter only).
    pub debug_filter: Option<String>,
    /// Debug runs: quit once the report is in.
    pub debug_quit: bool,
    /// Debug runs: show the panel at launch and keep it up when it loses focus.
    pub debug_show: bool,
    /// Started at login (the autostart entry): just the tray. A second launch with it (DigUp is running already)
    /// doesn't show the panel either.
    pub background: bool,
    /// `--add-folder DIR --from-tool NAME --yes`: added by the running DigUp without its window, as a tool asks
    /// (tools.rs): the tool's name, and that it was meant (`--yes`).
    pub from_tool: Option<String>,
    pub yes: bool,
    /// With `--from-tool`: at most this many files (default tools::MAX_FILES).
    pub max_files: Option<u32>,
}

impl Options {
    pub fn from_args() -> Result<Options, String> {
        Options::parse(std::env::args().skip(1))
    }

    /// The options in these arguments (the program's name left out).
    pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Options, String> {
        let mut options = Options {
            helper: default_helper(),
            index: None,
            models: None,
            roots: Vec::new(),
            hotkey: None,
            settings: None,
            command: None,
            offered: None,
            debug_setup: false,
            debug_query: None,
            debug_filter: None,
            debug_quit: false,
            debug_show: false,
            background: false,
            from_tool: None,
            yes: false,
            max_files: None,
        };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
            match arg.as_str() {
                "--helper" => options.helper = value()?.into(),
                "--index" => options.index = Some(value()?.into()),
                "--models" => options.models = Some(value()?.into()),
                // Separated as PATH is: ":" here, ";" on Windows.
                "--roots" => options.roots = std::env::split_paths(&value()?).collect(),
                "--hotkey" => options.hotkey = Some(value()?),
                "--settings-file" => options.settings = Some(value()?.into()),
                "--offer" => options.offered = Some(std::env::split_paths(&value()?).collect()),
                "--debug-setup" => options.debug_setup = true,
                "--debug-query" => options.debug_query = Some(value()?),
                "--debug-filter" => options.debug_filter = Some(value()?),
                "--debug-quit" => options.debug_quit = true,
                "--debug-show" => options.debug_show = true,
                "--background" => options.background = true,
                "--from-tool" => options.from_tool = Some(value()?),
                "--yes" => options.yes = true,
                "--max-files" => {
                    let text = value()?;
                    let number = text.parse().map_err(|_| format!("--max-files takes a number, not {text}"))?;
                    options.max_files = Some(number);
                }
                "--add-folder" => {
                    let folder = PathBuf::from(value()?);
                    options.command = Some(Command::AddFolder(std::path::absolute(&folder).unwrap_or(folder)));
                }
                _ => match Command::of(&arg) {
                    Some(command) => options.command = Some(command),
                    None => return Err(format!("unknown argument {arg}")),
                },
            }
        }
        // On a Mac the shell is only tried out: the helper's default index there is the Mac app's.
        if cfg!(target_os = "macos") && options.index.is_none() {
            return Err("pass --index: on a Mac the default index belongs to the DigUp app".into());
        }
        Ok(options)
    }
}

/// What a launch asks of DigUp: `digup-shell --toggle` and so on. A launch while DigUp runs hands its arguments to the
/// running one (single instance), which does it; the GNOME shortcut runs `--toggle`, so the same keys close the panel.
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    /// The panel: shown when it's hidden, hidden when it's shown.
    Toggle,
    Show,
    Hide,
    /// Pause Indexing / Resume Indexing.
    Pause,
    Resume,
    /// The settings window.
    Settings,
    Quit,
    /// Index Now: a sync (unless indexing is paused).
    IndexNow,
    /// `--add-folder DIR`: the window that adds a folder on the spot, for this one (adding.rs). A relative path is
    /// relative to where the launch was started.
    AddFolder(PathBuf),
}

impl Command {
    pub fn of(arg: &str) -> Option<Command> {
        Some(match arg {
            "--toggle" => Command::Toggle,
            "--show" => Command::Show,
            "--hide" => Command::Hide,
            "--pause" => Command::Pause,
            "--resume" => Command::Resume,
            "--settings" => Command::Settings,
            "--quit" => Command::Quit,
            "--index-now" => Command::IndexNow,
            _ => return None,
        })
    }

    /// The command in a launch's arguments (the last, if there are several), as the running DigUp gets them: the
    /// program first, then everything it was started with (a dev launcher's --helper and such too). `--add-folder`'s
    /// folder is taken relative to `cwd`, where that launch was started.
    pub fn in_args(args: &[String], cwd: &str) -> Option<Command> {
        let args: Vec<&String> = args.iter().skip(1).collect();
        args.iter().enumerate().rev().find_map(|(at, arg)| match arg.as_str() {
            "--add-folder" => args.get(at + 1).map(|folder| Command::AddFolder(std::path::Path::new(cwd).join(folder))),
            // The folder after --add-folder isn't a command, whatever it's called.
            _ if at > 0 && args[at - 1] == "--add-folder" => None,
            _ => Command::of(arg),
        })
    }

    /// Worth starting DigUp for when it isn't running. Quitting, hiding, pausing or resuming one that isn't there
    /// isn't: the launch says so and ends (a pause or resume is kept in the settings for its next start).
    pub fn starts_app(&self) -> bool {
        matches!(self, Command::Toggle | Command::Show | Command::Settings | Command::IndexNow | Command::AddFolder(_))
    }
}

impl Options {
    /// `--add-folder DIR --from-tool NAME --yes [--max-files N]`: the folder, the tool and the cap, for the running
    /// DigUp to add without asking (tools.rs). None without `--from-tool`; an error when the rest is missing.
    pub fn tool_request(&self) -> Option<Result<(PathBuf, String, u32), String>> {
        let tool = self.from_tool.clone()?;
        let Some(Command::AddFolder(folder)) = self.command.clone() else {
            return Some(Err("--from-tool goes with --add-folder DIR".into()));
        };
        if !self.yes {
            return Some(Err("--from-tool adds the folder without asking: say --yes".into()));
        }
        Some(Ok((folder, tool, self.max_files.unwrap_or(crate::tools::MAX_FILES))))
    }

    /// The index folder the helpers use: the one given, else the helper's default (which the watcher must pass over).
    pub fn index_folder(&self) -> Option<PathBuf> {
        if self.index.is_some() {
            return self.index.clone();
        }
        helper_folder().map(|folder| folder.join("index"))
    }

    /// Where the model files are: the folder given, else the helper's default (AppPaths in the engine).
    pub fn models_folder(&self) -> Option<PathBuf> {
        if self.models.is_some() {
            return self.models.clone();
        }
        helper_folder().map(|folder| folder.join("Models"))
    }

    /// The settings file: the one given, else the one a DigUp with this identifier keeps in its config folder (as
    /// Tauri's app_config_dir has it: $XDG_CONFIG_HOME/<identifier> or ~/.config/<identifier> on Linux,
    /// %APPDATA%\<identifier> on Windows). For a launch that doesn't start the app.
    pub fn settings_file(&self, identifier: &str) -> Option<PathBuf> {
        if self.settings.is_some() {
            return self.settings.clone();
        }
        let config = if cfg!(windows) {
            std::env::var_os("APPDATA").map(PathBuf::from)
        } else {
            std::env::var_os("XDG_CONFIG_HOME").filter(|value| !value.is_empty()).map(PathBuf::from)
                .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        };
        config.map(|config| config.join(identifier).join("settings.json"))
    }
}

/// The helper's own folder (`AppPaths.applicationSupport`): %LOCALAPPDATA%\DigUp on Windows, $XDG_DATA_HOME/digup
/// (~/.local/share/digup) on Linux.
fn helper_folder() -> Option<PathBuf> {
    if cfg!(windows) {
        return std::env::var_os("LOCALAPPDATA").map(|local| PathBuf::from(local).join("DigUp"));
    }
    let data = std::env::var_os("XDG_DATA_HOME").filter(|value| !value.is_empty()).map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
    data.map(|data| data.join("digup"))
}

/// The helper beside this program, or in its `helper` folder (a test build keeps the helper and its libraries there:
/// on Windows "DigUp.exe" and "digup.exe" can't share a folder).
fn default_helper() -> PathBuf {
    let name = if cfg!(windows) { "digup.exe" } else { "digup" };
    let Some(folder) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(PathBuf::from)) else {
        return PathBuf::from(name);
    };
    let inside = folder.join("helper").join(name);
    if inside.is_file() { inside } else { folder.join(name) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| arg.to_string()).collect()
    }

    #[test]
    fn commands_from_a_second_launch() {
        let in_args = |list: &[&str]| Command::in_args(&args(list), "/home/me");
        assert_eq!(in_args(&["digup-shell", "--toggle"]), Some(Command::Toggle));
        // The dev launcher passes its own arguments first.
        assert_eq!(in_args(&["digup-shell", "--helper", "/x/digup", "--hotkey", "Control+Alt+Space", "--index-now"]),
                   Some(Command::IndexNow));
        assert_eq!(in_args(&["digup-shell", "--pause", "--resume"]), Some(Command::Resume), "the last");
        assert_eq!(in_args(&["digup-shell"]), None);
        assert_eq!(in_args(&["digup-shell", "--background"]), None);
        assert_eq!(in_args(&["--quit"]), None, "the program's own name isn't an argument");
        assert!(Command::Settings.starts_app() && Command::Toggle.starts_app() && Command::IndexNow.starts_app());
        assert!(!Command::Quit.starts_app() && !Command::Pause.starts_app() && !Command::Hide.starts_app());
    }

    #[test]
    fn a_folder_to_add() {
        let in_args = |list: &[&str]| Command::in_args(&args(list), "/home/me");
        assert_eq!(in_args(&["digup-shell", "--add-folder", "/data/photos"]),
                   Some(Command::AddFolder("/data/photos".into())));
        assert_eq!(in_args(&["digup-shell", "--add-folder", "git/app"]), Some(Command::AddFolder("/home/me/git/app".into())),
                   "relative to where it was started");
        assert_eq!(in_args(&["digup-shell", "--add-folder", "--quit"]), Some(Command::AddFolder("/home/me/--quit".into())),
                   "a folder with a command's name is a folder");
        assert_eq!(in_args(&["digup-shell", "--add-folder"]), None, "no folder: nothing to do");
        assert!(Command::AddFolder("/x".into()).starts_app());
    }

    #[test]
    fn a_folder_a_tool_adds() {
        let request = |list: &[&str]| Options::parse(args(list)).map(|options| options.tool_request());
        assert_eq!(request(&["--add-folder", "/home/me/git/app"]), Ok(None), "the add window's, not a tool's");
        assert_eq!(request(&["--add-folder", "/home/me/git/app", "--from-tool", "claude-code", "--yes"]),
                   Ok(Some(Ok(("/home/me/git/app".into(), "claude-code".into(), crate::tools::MAX_FILES)))));
        assert_eq!(request(&["--from-tool", "x", "--yes", "--max-files", "500", "--add-folder", "/data"]),
                   Ok(Some(Ok(("/data".into(), "x".into(), 500)))));
        let unasked = request(&["--add-folder", "/data", "--from-tool", "x"]).unwrap().unwrap();
        assert!(unasked.unwrap_err().contains("--yes"));
        assert!(request(&["--from-tool", "x", "--yes"]).unwrap().unwrap().unwrap_err().contains("--add-folder"));
        assert!(request(&["--max-files", "lots"]).unwrap_err().contains("takes a number"));
    }
}
