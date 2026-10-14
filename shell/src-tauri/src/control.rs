//! Control from outside: `digup-shell --quit` and the like (options.rs's `Command`). While DigUp runs, a second launch
//! hands its arguments to it (tauri-plugin-single-instance, over D-Bus on Linux) and main.rs's `act` does what they
//! say. When it isn't running, a command that isn't worth starting it for (`Command::starts_app`) is answered here,
//! before Tauri starts: a script's `--quit` mustn't start DigUp only to quit it.

use crate::options::Command;
use crate::settings::Settings;
use std::path::Path;

/// A DigUp with this identifier is running: its single-instance name is taken on the session bus (the name
/// tauri-plugin-single-instance takes on Linux: "<identifier>.SingleInstance"). No session bus: none can be.
#[cfg(target_os = "linux")]
pub fn is_running(identifier: &str) -> bool {
    let name = format!("{identifier}.SingleInstance");
    let Ok(bus_name) = zbus::names::BusName::try_from(name.as_str()) else { return false };
    let Ok(connection) = zbus::blocking::Connection::session() else { return false };
    let Ok(bus) = zbus::blocking::fdo::DBusProxy::new(&connection) else { return false };
    bus.name_has_owner(bus_name).unwrap_or(false)
}

/// What a command does when DigUp isn't running: what's printed, and the exit status. Quit and hide have nothing to
/// do; a pause or resume is saved in `settings` (a settings file that isn't there yet is made), so it holds from the
/// next start, as the tray's Pause Indexing does.
pub fn when_not_running(command: Command, settings: Option<&Path>) -> (String, i32) {
    let paused = match command {
        Command::Pause => true,
        Command::Resume => false,
        _ => return ("DigUp isn't running".into(), 0),
    };
    let Some(file) = settings else { return ("DigUp isn't running, and its settings can't be found".into(), 1) };
    let mut chosen = Settings::load(file);
    let said = match (paused, chosen.paused) {
        (true, true) => "DigUp isn't running; indexing was paused already",
        (true, false) => "DigUp isn't running; indexing will be paused when it starts",
        (false, true) => "DigUp isn't running; indexing will resume when it starts",
        (false, false) => "DigUp isn't running; indexing wasn't paused",
    };
    if chosen.paused == paused {
        return (said.into(), 0);
    }
    chosen.paused = paused;
    match chosen.save(file) {
        Ok(()) => (said.into(), 0),
        Err(error) => (format!("DigUp isn't running, and its settings can't be saved: {error}"), 1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn nobody_runs_a_made_up_digup() {
        assert!(!is_running("org.digup.test.NobodyHasThis"));
    }

    #[test]
    fn a_pause_without_digup_waits_in_the_settings() {
        let folder = std::env::temp_dir().join(format!("digup-control-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        let file = folder.join("settings.json");
        assert_eq!(when_not_running(Command::Quit, Some(&file)), ("DigUp isn't running".to_string(), 0));
        assert_eq!(when_not_running(Command::Hide, None).1, 0);
        assert!(!file.exists(), "quitting changes nothing");

        let (said, status) = when_not_running(Command::Pause, Some(&file));
        assert_eq!((said.as_str(), status), ("DigUp isn't running; indexing will be paused when it starts", 0));
        assert!(Settings::load(&file).paused);
        assert!(when_not_running(Command::Pause, Some(&file)).0.ends_with("paused already"));
        // The rest of the settings stay as they were.
        let mut chosen = Settings::load(&file);
        chosen.folders = vec!["/home/me/Documents".into()];
        chosen.save(&file).unwrap();
        assert!(when_not_running(Command::Resume, Some(&file)).0.ends_with("resume when it starts"));
        let after = Settings::load(&file);
        assert!(!after.paused);
        assert_eq!(after.folders, ["/home/me/Documents"]);
        assert_eq!(when_not_running(Command::Resume, None).1, 1);
        let _ = std::fs::remove_dir_all(folder);
    }
}
