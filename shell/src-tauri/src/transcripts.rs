//! Transcripts of recordings (PLANS/TRANSCRIPTS_PLAN.md): what's said in recordings and videos, searchable word for
//! word. The index helper makes them in a pass after everything else (`--transcripts gpu|cpu|off`), with whisper.cpp's
//! `whisper-cli`, a program of its own as ffmpeg is. Off by default: whisper costs about 7× the audio's embedding time,
//! and a model of its own (575 MB; 489 MB for the CPU), which `digup download-model --transcripts [--small]` fetches
//! when they're turned on. Here: what the helpers are started with, where whisper-cli is, and the download's state.

use crate::settings::Settings;
use serde_json::{json, Value};
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// What the index helper is told: "gpu" (whisper large-v3-turbo on the GPU) when they're on and the GPU is in use,
/// "cpu" (whisper small on the processor: the GPU switched off, or failed this session) when they're on, else "off",
/// which takes an index's transcripts out. Always said: a helper started without it takes them out too.
pub fn mode(on: bool, gpu: bool) -> &'static str {
    match (on, gpu) {
        (false, _) => "off",
        (true, true) => "gpu",
        (true, false) => "cpu",
    }
}

/// The index helper's transcript arguments: the mode, and songs too when Settings say so.
pub fn arguments(settings: &Settings, gpu: bool) -> Vec<String> {
    let mut args = vec!["--transcripts".to_string(), mode(settings.transcripts, gpu).to_string()];
    if settings.transcripts && settings.transcribe_music {
        args.push("--transcribe-music".to_string());
    }
    args
}

/// `digup download-model --transcripts`: the model the mode needs (`--small` for the CPU) and the VAD, into the models
/// folder's whisper/ (`--to` when the shell was told where the models are; the helper looks in DIGUP_MODELS/whisper).
/// Files already there are kept: with everything in, it says "done" at once.
pub fn download_arguments(gpu: bool, models: Option<&Path>) -> Vec<String> {
    let mut args = vec!["download-model".to_string(), "--transcripts".to_string()];
    if !gpu {
        args.push("--small".to_string());
    }
    if let Some(models) = models {
        args.extend(["--to".to_string(), models.display().to_string()]);
    }
    args
}

/// whisper-cli, where the helper looks for it (Transcribe+Portable.swift's `find`): $DIGUP_WHISPER (the program, or
/// its folder), beside the helper (where install-user.sh puts it), in the checkout's Vendor/whisper/bin when the
/// helper is a dev build in .build/, then on PATH. None: this build has no transcripts, and Settings says so.
pub fn whisper(helper: &Path, chosen: Option<&str>, path: Option<&OsStr>) -> Option<PathBuf> {
    let name = if cfg!(windows) { "whisper-cli.exe" } else { "whisper-cli" };
    let mut folders: Vec<PathBuf> = Vec::new();
    if let Some(chosen) = chosen.filter(|chosen| !chosen.is_empty()) {
        let chosen = PathBuf::from(chosen);
        if chosen.is_file() && is_executable(&chosen) {
            return Some(chosen);
        }
        folders.push(chosen);
    }
    if let Some(folder) = helper.parent().filter(|folder| !folder.as_os_str().is_empty()) {
        folders.push(folder.to_path_buf());
    }
    let shown = helper.display().to_string();
    if let Some(build) = shown.find("/.build/") {
        folders.push(PathBuf::from(&shown[..build]).join("Vendor/whisper/bin"));
    }
    folders.extend(path.map(|path| std::env::split_paths(path).collect::<Vec<_>>()).unwrap_or_default());
    folders.into_iter().map(|folder| folder.join(name)).find(|candidate| candidate.is_file() && is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|meta| meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The download's state for Settings, from one of `digup download-model`'s events (DownloadModel.swift):
/// {"state": "checking|downloading|waiting|ready|failed", "bytes", "total", "problem" (a failure it tries again
/// after), "message" (why it failed)}. None: an event that changes nothing.
pub fn state(event: &Value) -> Option<Value> {
    Some(match event["event"].as_str()? {
        "progress" => json!({"state": "downloading", "bytes": event["all_bytes"], "total": event["all_total"]}),
        "file" => json!({"state": "downloading"}),
        "verifying" => json!({"state": "checking"}),
        "waiting" => json!({"state": "waiting"}),
        "retry" => json!({"state": "downloading", "problem": event["message"]}),
        "done" => json!({"state": "ready"}),
        "error" => json!({"state": "failed", "message": event["message"]}),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_the_index_helper_is_told() {
        let off = Settings::default();
        assert!(!off.transcripts && !off.transcribe_music, "off unless turned on");
        assert_eq!(arguments(&off, true), ["--transcripts", "off"], "said, so an index's transcripts go");
        let on = Settings { transcripts: true, ..Settings::default() };
        assert_eq!(arguments(&on, true), ["--transcripts", "gpu"]);
        assert_eq!(arguments(&on, false), ["--transcripts", "cpu"], "the GPU off, or failed this session");
        let songs = Settings { transcribe_music: true, ..on };
        assert_eq!(arguments(&songs, true), ["--transcripts", "gpu", "--transcribe-music"]);
        assert_eq!(arguments(&Settings { transcripts: false, ..songs }, true), ["--transcripts", "off"]);
    }

    #[test]
    fn the_download_for_each_mode() {
        assert_eq!(download_arguments(true, None), ["download-model", "--transcripts"]);
        assert_eq!(download_arguments(false, Some(Path::new("/m"))),
                   ["download-model", "--transcripts", "--small", "--to", "/m"]);
    }

    #[test]
    fn the_downloads_events() {
        let progress = json!({"event": "progress", "name": "x", "bytes": 5, "total": 9, "all_bytes": 50, "all_total": 90});
        assert_eq!(state(&progress), Some(json!({"state": "downloading", "bytes": 50, "total": 90})));
        assert_eq!(state(&json!({"event": "done", "folder": "/m/whisper"})).unwrap()["state"], "ready");
        let failed = state(&json!({"event": "error", "message": "no network"})).unwrap();
        assert_eq!((failed["state"].as_str(), failed["message"].as_str()), (Some("failed"), Some("no network")));
        assert_eq!(state(&json!({"event": "retry", "message": "timed out", "seconds": 2})).unwrap()["problem"], "timed out");
        assert_eq!(state(&json!({"event": "something new"})), None);
    }

    #[cfg(unix)]
    #[test]
    fn where_whisper_cli_is_found() {
        use std::os::unix::fs::PermissionsExt;
        let folder = std::env::temp_dir().join(format!("digup-whisper-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        let make = |path: &Path| {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        };
        let installed = folder.join("opt/helper/digup");
        assert_eq!(whisper(&installed, None, None), None, "not in this build");
        make(&folder.join("opt/helper/whisper-cli"));
        assert_eq!(whisper(&installed, None, None), Some(folder.join("opt/helper/whisper-cli")), "beside the helper");
        // A dev build: the checkout's Vendor/whisper/bin.
        let dev = folder.join("repo/.build/release/digup");
        make(&folder.join("repo/Vendor/whisper/bin/whisper-cli"));
        assert_eq!(whisper(&dev, None, None), Some(folder.join("repo/Vendor/whisper/bin/whisper-cli")));
        // DIGUP_WHISPER first, a program or a folder; then PATH.
        make(&folder.join("chosen/whisper-cli"));
        let chosen = folder.join("chosen/whisper-cli").display().to_string();
        assert_eq!(whisper(&dev, Some(&chosen), None).as_deref(), Some(Path::new(&chosen)));
        let chosen_folder = folder.join("chosen").display().to_string();
        assert_eq!(whisper(&dev, Some(&chosen_folder), None).as_deref(), Some(Path::new(&chosen)));
        let path = std::ffi::OsString::from(folder.join("chosen"));
        assert_eq!(whisper(Path::new("digup"), None, Some(&path)).as_deref(), Some(Path::new(&chosen)));
        // Not a program: not found.
        std::fs::set_permissions(folder.join("chosen/whisper-cli"), std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(whisper(Path::new("digup"), None, Some(&path)), None);
        let _ = std::fs::remove_dir_all(folder);
    }
}
