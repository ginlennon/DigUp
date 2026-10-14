//! What the person chose: the folders DigUp searches, what it skips in them, the hotkey, whether setup is done,
//! whether indexing is paused and may use the GPU, where recordings open at a moment. A JSON file in the app's config
//! folder (%APPDATA%\com.abdurrahim.DigUp on Windows, ~/.config/com.abdurrahim.DigUp on Linux). Launch arguments
//! (`--roots`, `--hotkey`) stand in for it in dev runs. A field a file doesn't have yet (one saved by an older shell)
//! takes its default.

use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// The folders searched and kept indexed.
    pub folders: Vec<String>,
    /// Folders inside them that aren't (`FolderSelection` in the engine).
    pub skipped: Vec<String>,
    /// File extensions left out ("heic", "txt").
    pub skip_types: Vec<String>,
    /// The panel's hotkey (Tauri's accelerator form); empty: the default.
    pub hotkey: String,
    /// Onboarding is done: the shell starts in the tray.
    pub set_up: bool,
    /// Pause Indexing: the index helper doesn't run (not for changes either) until it's resumed, also after a
    /// restart. Search works as ever.
    pub paused: bool,
    /// The model may run on the GPU (Vulkan); off, the helpers get DIGUP_GPU=0 and use the CPU only.
    pub gpu: bool,
    /// Where a recording opens when its result has a moment: "vlc" (VLC when it's installed, else as "default") or
    /// "default" (the file's default app, told the moment if it can be: opener.rs).
    pub moment_player: String,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            folders: Vec::new(),
            skipped: Vec::new(),
            skip_types: Vec::new(),
            hotkey: String::new(),
            set_up: false,
            paused: false,
            gpu: true,
            moment_player: "vlc".to_string(),
        }
    }
}

impl Settings {
    /// Recordings with a moment open in VLC when it's there (anything but "default" reads as "vlc").
    pub fn prefers_vlc(&self) -> bool {
        self.moment_player != "default"
    }

    /// The file's settings, or the defaults when there's none (or it can't be read).
    pub fn load(path: &Path) -> Settings {
        std::fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    /// Written whole to a temporary file first, so a crash never leaves half of it.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let temporary = path.with_extension("json.new");
        std::fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(temporary, path)
    }
}

/// The extensions typed in Settings ("HEIC, .txt  mp3"): lowercase, without dots, each once.
pub fn extensions(text: &str) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for word in text.split(|c: char| c == ',' || c.is_whitespace()) {
        let extension = word.trim().trim_start_matches('.').to_lowercase();
        if !extension.is_empty() && !found.contains(&extension) {
            found.push(extension);
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_older_file_still_loads() {
        let old: Settings = serde_json::from_str(r#"{"folders":["/home/me/Documents"],"skipTypes":["heic"],"setUp":true}"#)
            .unwrap();
        assert_eq!(old.folders, ["/home/me/Documents"]);
        assert!(old.set_up && old.gpu && !old.paused, "new fields take their defaults");
        assert!(old.prefers_vlc());
        let chosen: Settings = serde_json::from_str(r#"{"momentPlayer":"default"}"#).unwrap();
        assert!(!chosen.prefers_vlc());
        let written = serde_json::to_value(Settings { paused: true, gpu: false, ..old }).unwrap();
        assert_eq!((written["paused"].as_bool(), written["gpu"].as_bool()), (Some(true), Some(false)));
    }

    #[test]
    fn typed_extensions() {
        assert_eq!(extensions("HEIC, .txt  mp3,,heic"), ["heic", "txt", "mp3"]);
        assert!(extensions(" , ").is_empty());
    }
}
