//! What Settings sets up in a Linux desktop: the GNOME shortcut that opens the panel, and starting at login.
//!
//! - The shortcut: apps can't grab keys globally on Wayland, and GNOME 46 has no GlobalShortcuts portal, so the hotkey
//!   is a GNOME custom shortcut that runs this program again; the running shell (single instance) shows its panel. It's
//!   written with gsettings as scripts/linux/gnome-shortcut.sh writes it: our path is added to the list of custom
//!   shortcuts, the others are kept.
//! - Starting at login: ~/.config/autostart/digup.desktop (the XDG autostart spec), with `--background` so a login
//!   shows nothing but the tray. A file this small doesn't need tauri-plugin-autostart.
//!
//! Both run "this program": the dev launcher when DIGUP_SHELL_LAUNCHER names one (scripts/linux/dev-run-shell.sh,
//! which passes the helper and the libraries), else this executable.

use serde::Serialize;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const SCHEMA: &str = "org.gnome.settings-daemon.plugins.media-keys";
/// Our custom shortcut's settings path (the script's too, so either one updates the other's).
const KEYBINDING: &str = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/";

/// A GNOME session: XDG_CURRENT_DESKTOP lists GNOME ("ubuntu:GNOME" on Ubuntu).
pub fn is_gnome(current_desktop: Option<&str>) -> bool {
    current_desktop.is_some_and(|desktops| desktops.split(':').any(|desktop| desktop.eq_ignore_ascii_case("gnome")))
}

/// The command that starts DigUp: the dev launcher, else this executable.
pub fn launcher() -> String {
    if let Some(launcher) = std::env::var("DIGUP_SHELL_LAUNCHER").ok().filter(|value| !value.is_empty()) {
        return launcher;
    }
    std::env::current_exe().map(|exe| exe.display().to_string()).unwrap_or_else(|_| "digup-shell".into())
}

// MARK: The GNOME shortcut

/// Tauri's "Control+Alt+Space" as GNOME writes it: "<Control><Alt>space".
pub fn gnome_binding(accelerator: &str) -> String {
    let parts: Vec<&str> = accelerator.split('+').map(str::trim).collect();
    let (key, modifiers) = parts.split_last().map(|(key, rest)| (*key, rest)).unwrap_or(("space", &[]));
    let mut binding = String::new();
    for modifier in modifiers {
        binding.push_str(match modifier.to_lowercase().as_str() {
            "control" | "ctrl" | "commandorcontrol" | "cmdorctrl" => "<Control>",
            "alt" | "option" => "<Alt>",
            "shift" => "<Shift>",
            _ => "<Super>",
        });
    }
    let key = if key.chars().count() == 1 || key.eq_ignore_ascii_case("space") { key.to_lowercase() } else { key.into() };
    binding + &key
}

/// GNOME's "<Control><Alt>space" as people read it here: "Ctrl+Alt+Space".
pub fn binding_text(binding: &str) -> String {
    let mut parts = Vec::new();
    let mut rest = binding;
    while let Some(after) = rest.strip_prefix('<') {
        let Some(end) = after.find('>') else { break };
        parts.push(match &after[..end] {
            "Control" | "Primary" | "Ctrl" => "Ctrl".to_string(),
            "Super" => "Super".to_string(),
            other => other.to_string(),
        });
        rest = &after[end + 1..];
    }
    let mut key = rest.to_string();
    if let Some(first) = key.get(..1) {
        key = first.to_uppercase() + &key[1..];
    }
    parts.push(key);
    parts.join("+")
}

/// A string in GVariant's text form, which gsettings reads: '…' with \ and ' escaped.
pub fn gvariant_string(text: &str) -> String {
    format!("'{}'", text.replace('\\', "\\\\").replace('\'', "\\'"))
}

/// The strings of gsettings' answer: "['/a/', '/b/']", "@as []", "'<Control><Alt>space'".
pub fn gvariant_strings(text: &str) -> Vec<String> {
    let mut strings = Vec::new();
    let mut chars = text.trim().trim_start_matches("@as").chars();
    while let Some(c) = chars.next() {
        if c != '\'' && c != '"' {
            continue;
        }
        let mut string = String::new();
        while let Some(inside) = chars.next() {
            match inside {
                '\\' => string.extend(chars.next()),
                quote if quote == c => break,
                other => string.push(other),
            }
        }
        strings.push(string);
    }
    strings
}

/// The list of custom shortcuts with ours added (once), in gsettings' text form.
pub fn with_ours(list: &[String]) -> String {
    let mut paths: Vec<String> = list.to_vec();
    if !paths.iter().any(|path| path == KEYBINDING) {
        paths.push(KEYBINDING.to_string());
    }
    format!("[{}]", paths.iter().map(|path| gvariant_string(path)).collect::<Vec<_>>().join(", "))
}

/// A path for a shell-like command line (GNOME splits the shortcut's command as a shell would): quoted only if needed.
pub fn shell_word(word: &str) -> String {
    if !word.is_empty() && word.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+:@%=,".contains(c)) {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', "'\\''"))
}

/// What GNOME has for our shortcut.
#[derive(Clone, Debug, Default, Serialize)]
pub struct Shortcut {
    /// Ours is in GNOME's list of custom shortcuts.
    pub installed: bool,
    /// Its keys, as people read them ("Ctrl+Alt+Space").
    pub keys: String,
    /// What it runs.
    pub command: String,
}

fn gsettings(args: &[&str]) -> Result<String, String> {
    let output = Command::new("gsettings").args(args).stdin(Stdio::null()).output()
        .map_err(|error| format!("can't run gsettings: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Our GNOME shortcut as it is now (None: gsettings can't say, so it isn't GNOME's to set).
pub fn gnome_shortcut() -> Option<Shortcut> {
    let list = gvariant_strings(&gsettings(&["get", SCHEMA, "custom-keybindings"]).ok()?);
    let ours = format!("{SCHEMA}.custom-keybinding:{KEYBINDING}");
    let get = |key: &str| gsettings(&["get", &ours, key]).ok().and_then(|text| gvariant_strings(&text).pop());
    let (binding, command) = (get("binding").unwrap_or_default(), get("command").unwrap_or_default());
    Some(Shortcut {
        installed: list.iter().any(|path| path == KEYBINDING) && !binding.is_empty() && !command.is_empty(),
        keys: if binding.is_empty() { String::new() } else { binding_text(&binding) },
        command,
    })
}

/// Writes our GNOME shortcut: `accelerator` (Tauri's form) runs `command`.
pub fn set_up_gnome_shortcut(accelerator: &str, command: &str) -> Result<(), String> {
    let list = gvariant_strings(&gsettings(&["get", SCHEMA, "custom-keybindings"])?);
    gsettings(&["set", SCHEMA, "custom-keybindings", &with_ours(&list)])?;
    let ours = format!("{SCHEMA}.custom-keybinding:{KEYBINDING}");
    gsettings(&["set", &ours, "name", &gvariant_string("DigUp search")])?;
    gsettings(&["set", &ours, "command", &gvariant_string(command)])?;
    gsettings(&["set", &ours, "binding", &gvariant_string(&gnome_binding(accelerator))])?;
    Ok(())
}

// MARK: Starting at login

/// ~/.config/autostart/digup.desktop ($XDG_CONFIG_HOME's autostart folder).
pub fn autostart_file() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME").filter(|value| !value.is_empty()).map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(config.join("autostart").join("digup.desktop"))
}

/// A word of a .desktop file's Exec line: in double quotes, with " ` $ \ escaped, when it has anything but plain
/// path characters (the desktop entry spec).
pub fn exec_word(word: &str) -> String {
    if !word.is_empty() && word.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+,:@".contains(c)) {
        return word.to_string();
    }
    let mut quoted = String::from("\"");
    for c in word.chars() {
        if "\"`$\\".contains(c) {
            quoted.push('\\');
        }
        quoted.push(c);
    }
    quoted + "\""
}

/// The autostart entry that starts `command` in the tray.
pub fn autostart_entry(command: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=DigUp\nComment=Search your files by what's in them\n\
         Exec={} --background\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        exec_word(command)
    )
}

/// DigUp starts at login: its entry is there and isn't switched off (Hidden=true, or GNOME's own switch).
pub fn starts_at_login() -> bool {
    let Some(text) = autostart_file().and_then(|file| std::fs::read_to_string(file).ok()) else { return false };
    !text.lines().any(|line| {
        let line = line.replace(' ', "");
        line == "Hidden=true" || line == "X-GNOME-Autostart-enabled=false"
    })
}

pub fn set_starts_at_login(on: bool, command: &str) -> Result<(), String> {
    let file = autostart_file().ok_or("no home folder")?;
    if !on {
        return match std::fs::remove_file(&file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.to_string()),
            _ => Ok(()),
        };
    }
    if let Some(folder) = file.parent() {
        std::fs::create_dir_all(folder).map_err(|error| error.to_string())?;
    }
    std::fs::write(&file, autostart_entry(command)).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gnome_sessions() {
        assert!(is_gnome(Some("ubuntu:GNOME")));
        assert!(is_gnome(Some("GNOME")));
        assert!(!is_gnome(Some("KDE")));
        assert!(!is_gnome(None));
    }

    #[test]
    fn bindings_both_ways() {
        assert_eq!(gnome_binding("Control+Alt+Space"), "<Control><Alt>space");
        assert_eq!(gnome_binding("CommandOrControl+Shift+K"), "<Control><Shift>k");
        assert_eq!(gnome_binding("Super+F5"), "<Super>F5");
        assert_eq!(binding_text("<Control><Alt>space"), "Ctrl+Alt+Space");
        assert_eq!(binding_text("<Primary><Shift>k"), "Ctrl+Shift+K");
    }

    #[test]
    fn the_list_keeps_other_shortcuts() {
        let list = gvariant_strings("['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']");
        assert_eq!(with_ours(&list),
                   "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', \
                    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/']");
        // Ours is there once, however often it's set up.
        assert_eq!(with_ours(&gvariant_strings(&with_ours(&[]))), format!("['{KEYBINDING}']"));
        assert!(gvariant_strings("@as []").is_empty());
        assert_eq!(gvariant_strings(r"'it\'s'"), ["it's"]);
        assert_eq!(gvariant_string(r"a'b\c"), r"'a\'b\\c'");
    }

    #[test]
    fn commands_quoted_where_needed() {
        assert_eq!(shell_word("/home/me/bin/digup-shell"), "/home/me/bin/digup-shell");
        assert_eq!(shell_word("/home/me/My Apps/digup-shell"), "'/home/me/My Apps/digup-shell'");
        assert_eq!(exec_word("/opt/DigUp/digup-shell"), "/opt/DigUp/digup-shell");
        assert_eq!(exec_word("/home/me/My $Apps/digup"), r#""/home/me/My \$Apps/digup""#);
        assert!(autostart_entry("/opt/DigUp/digup-shell").contains("\nExec=/opt/DigUp/digup-shell --background\n"));
    }
}
