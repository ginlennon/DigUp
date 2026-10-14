//! The editors code results open in, at the line that matched (as the Mac app's CodeEditors.swift): found by their
//! commands on $PATH (and JetBrains Toolbox's scripts folder). Settings' "Open code in" picks one; until it's set, the
//! first one installed in `KNOWN`'s order, else the file's default app. How each is told the line is opener.rs's
//! (`Viewer`): VS Code and its forks `-g file:line`, Zed and Sublime Text `file:line`, Geany `--line=N`, JetBrains IDEs
//! `--line N`, Kate `-l N`; GNOME Text Editor opens the file at its start.

use crate::opener::App;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// An editor we know: its setting's id, its name, and the commands it's installed as (the first one found counts).
pub struct Known {
    pub id: &'static str,
    pub name: &'static str,
    commands: &'static [&'static str],
}

pub const KNOWN: &[Known] = &[
    Known { id: "code", name: "VS Code", commands: &["code"] },
    Known { id: "codium", name: "VSCodium", commands: &["codium"] },
    Known { id: "cursor", name: "Cursor", commands: &["cursor"] },
    Known { id: "zed", name: "Zed", commands: &["zed", "zeditor"] },
    Known { id: "subl", name: "Sublime Text", commands: &["subl"] },
    Known { id: "idea", name: "IntelliJ IDEA", commands: &["idea", "intellij-idea-ultimate", "intellij-idea-community"] },
    Known { id: "pycharm", name: "PyCharm", commands: &["pycharm", "pycharm-professional", "pycharm-community"] },
    Known { id: "webstorm", name: "WebStorm", commands: &["webstorm"] },
    Known { id: "clion", name: "CLion", commands: &["clion"] },
    Known { id: "goland", name: "GoLand", commands: &["goland"] },
    Known { id: "rustrover", name: "RustRover", commands: &["rustrover"] },
    Known { id: "phpstorm", name: "PhpStorm", commands: &["phpstorm"] },
    Known { id: "rubymine", name: "RubyMine", commands: &["rubymine"] },
    Known { id: "android-studio", name: "Android Studio", commands: &["android-studio"] },
    Known { id: "geany", name: "Geany", commands: &["geany"] },
    Known { id: "kate", name: "Kate", commands: &["kate"] },
    Known { id: "gnome-text-editor", name: "Text Editor", commands: &["gnome-text-editor"] },
];

/// The setting for "the file's default app" (the plain way, xdg-open; at its line only if that app can be told it).
pub const DEFAULT_APP: &str = "default";

/// An installed editor.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Editor {
    pub id: String,
    pub name: String,
    #[serde(skip)]
    pub program: PathBuf,
}

impl Editor {
    pub fn app(&self) -> App {
        App { id: self.id.clone(), program: self.program.display().to_string() }
    }
}

/// The known editors among these folders' programs (`is_program` says whether a path is one), in `KNOWN`'s order.
pub fn installed(folders: &[PathBuf], is_program: impl Fn(&Path) -> bool) -> Vec<Editor> {
    KNOWN
        .iter()
        .filter_map(|known| {
            let program = known.commands.iter().flat_map(|command| folders.iter().map(move |folder| folder.join(command)))
                .find(|path| is_program(path))?;
            Some(Editor { id: known.id.into(), name: known.name.into(), program })
        })
        .collect()
}

/// Where code results open for the setting `id`: that editor when it's installed; "" (not chosen yet), or one that's
/// gone, the first one installed; `DEFAULT_APP` (or nothing installed): None, the file's default app.
pub fn chosen(id: &str, installed: &[Editor]) -> Option<Editor> {
    if id == DEFAULT_APP {
        return None;
    }
    installed.iter().find(|editor| editor.id == id).or_else(|| installed.first()).cloned()
}

/// Where editors' commands are: $PATH, and the scripts JetBrains Toolbox puts in ~/.local/share/JetBrains/Toolbox.
fn folders() -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = std::env::var_os("PATH").map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    if let Some(home) = std::env::var_os("HOME") {
        folders.push(PathBuf::from(home).join(".local/share/JetBrains/Toolbox/scripts"));
    }
    folders
}

fn is_program(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata().is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    path.is_file()
}

/// The installed editors, looked up again after half a minute (one may have been installed meanwhile): the footer
/// asks on every move of the selection.
pub struct Editors(Mutex<Option<(Instant, Vec<Editor>)>>);

impl Editors {
    pub fn new() -> Editors {
        Editors(Mutex::new(None))
    }

    pub fn installed(&self) -> Vec<Editor> {
        let mut known = self.0.lock().unwrap();
        if let Some((when, editors)) = known.as_ref() {
            if when.elapsed() < Duration::from_secs(30) {
                return editors.clone();
            }
        }
        let editors = if cfg!(target_os = "linux") { installed(&folders(), is_program) } else { Vec::new() };
        *known = Some((Instant::now(), editors.clone()));
        editors
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn editors_found_and_chosen() {
        let bin = PathBuf::from("/usr/bin");
        let toolbox = PathBuf::from("/home/me/.local/share/JetBrains/Toolbox/scripts");
        let there = ["/usr/bin/zeditor", "/usr/bin/geany", "/home/me/.local/share/JetBrains/Toolbox/scripts/pycharm"];
        let found = installed(&[bin, toolbox], |path| there.iter().any(|program| Path::new(program) == path));
        let ids: Vec<&str> = found.iter().map(|editor| editor.id.as_str()).collect();
        assert_eq!(ids, ["zed", "pycharm", "geany"], "in the order of KNOWN");
        assert_eq!(found[0].program, PathBuf::from("/usr/bin/zeditor"), "Zed as some distributions name it");

        assert_eq!(chosen("geany", &found).map(|editor| editor.name), Some("Geany".into()));
        assert_eq!(chosen("", &found).map(|editor| editor.id), Some("zed".into()), "not chosen yet: the first one");
        assert_eq!(chosen("code", &found).map(|editor| editor.id), Some("zed".into()), "VS Code was uninstalled");
        assert_eq!(chosen(DEFAULT_APP, &found), None);
        assert_eq!(chosen("", &[]), None, "none installed: the default app");
    }
}
