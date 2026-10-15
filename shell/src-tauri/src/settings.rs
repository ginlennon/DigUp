//! What the person chose: the folders DigUp searches, what it skips in them, the hotkey, whether setup is done,
//! whether indexing is paused and may use the GPU, where recordings open at a moment, the code folders and the editor
//! code opens in, transcripts of recordings, and the search panel's size (on X11 its place too). A JSON file in the
//! app's config folder (%APPDATA%\com.abdurrahim.DigUp on Windows, ~/.config/com.abdurrahim.DigUp on Linux). Launch
//! arguments (`--roots`, `--hotkey`) stand in for it in dev runs. A field a file doesn't have yet (one saved by an
//! older shell) takes its default.

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
    /// Why DigUp paused indexing by itself ("Indexing paused: x.pdf kept failing", fallback.rs), so the tray and
    /// Settings still say it after a restart; none when it was paused by hand. Cleared on Resume.
    pub paused_why: Option<String>,
    /// The model may run on the GPU (Vulkan); off, the helpers get DIGUP_GPU=0 and use the CPU only.
    pub gpu: bool,
    /// Where a recording opens when its result has a moment: "vlc" (VLC when it's installed, else as "default") or
    /// "default" (the file's default app, told the moment if it can be: opener.rs).
    pub moment_player: String,
    /// Code search: the folders (repos, or folders of repos) kept in the code index (`--code-root`); none: off.
    pub code_folders: Vec<String>,
    /// Folders inside them that aren't (`--code-exclude`).
    pub code_skipped: Vec<String>,
    /// Where code results open (editors.rs): an editor's id, "default" (the file's default app), or "" (not chosen
    /// yet: the first editor installed).
    pub code_editor: String,
    /// Transcripts of recordings (transcripts.rs): what's said in recordings and videos is searchable word for word.
    /// Off unless turned on: they cost about 7× the audio's indexing time, and a model download.
    pub transcripts: bool,
    /// Songs (audio with artist and album tags) get transcripts too; off, they're skipped.
    pub transcribe_music: bool,
    /// The search panel's width and its height with results, as the person resized it (logical pixels; panel.rs
    /// keeps them within reason).
    pub panel_width: f64,
    pub panel_height: f64,
    /// X11: where the person dragged the panel (physical pixels); none: centered. Wayland doesn't let an app place
    /// its window, so it stays none there.
    pub panel_position: Option<[i32; 2]>,
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
            paused_why: None,
            gpu: true,
            moment_player: "vlc".to_string(),
            code_folders: Vec::new(),
            code_skipped: Vec::new(),
            code_editor: String::new(),
            transcripts: false,
            transcribe_music: false,
            panel_width: crate::panel::DEFAULT_WIDTH,
            panel_height: crate::panel::DEFAULT_HEIGHT,
            panel_position: None,
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
        assert!(old.set_up && old.gpu && !old.paused && old.paused_why.is_none(), "new fields take their defaults");
        assert!(old.prefers_vlc());
        assert!(old.code_folders.is_empty() && old.code_skipped.is_empty() && old.code_editor.is_empty());
        assert!(!old.transcripts && !old.transcribe_music, "transcripts are off unless turned on");
        assert_eq!((old.panel_width, old.panel_height, old.panel_position), (780.0, 480.0, None), "the panel's size");
        let sized: Settings = serde_json::from_str(r#"{"panelWidth":1000,"panelHeight":620.5,"panelPosition":[40,30]}"#)
            .unwrap();
        assert_eq!((sized.panel_width, sized.panel_height, sized.panel_position), (1000.0, 620.5, Some([40, 30])));
        let words: Settings = serde_json::from_str(r#"{"transcripts":true,"transcribeMusic":true}"#).unwrap();
        assert!(words.transcripts && words.transcribe_music);
        let chosen: Settings = serde_json::from_str(r#"{"momentPlayer":"default"}"#).unwrap();
        assert!(!chosen.prefers_vlc());
        let code: Settings = serde_json::from_str(r#"{"codeFolders":["/home/me/git"],"codeEditor":"zed"}"#).unwrap();
        assert_eq!((code.code_folders, code.code_editor), (vec!["/home/me/git".to_string()], "zed".to_string()));
        let why = Some("Indexing paused: Big.pdf kept failing".to_string());
        let written = serde_json::to_value(Settings { paused: true, paused_why: why.clone(), gpu: false, ..old }).unwrap();
        assert_eq!((written["paused"].as_bool(), written["gpu"].as_bool()), (Some(true), Some(false)));
        assert_eq!((written["panelWidth"].as_f64(), written["panelHeight"].as_f64()), (Some(780.0), Some(480.0)));
        assert_eq!(serde_json::from_value::<Settings>(written).unwrap().paused_why, why, "kept for the next start");
    }

    #[test]
    fn typed_extensions() {
        assert_eq!(extensions("HEIC, .txt  mp3,,heic"), ["heic", "txt", "mp3"]);
        assert!(extensions(" , ").is_empty());
    }
}
