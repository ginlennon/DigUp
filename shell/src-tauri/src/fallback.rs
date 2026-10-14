//! What the shell does when a helper ends badly (PLANS/LINUX_PORT_PLAN.md C1). A desktop GPU's Vulkan driver can crash
//! (DeviceLost) or hang, and the model then takes its helper down with it:
//! - The index helper's watchdog ends it on a file whose reading runs away (exit 75, the file noted in
//!   `<index>/stopped-file.json`; the next helper marks that file and goes on): restarted, at most 3 times in 10
//!   minutes, as the Mac app does (Engine.swift's `helperExited`); then indexing pauses and says which file.
//! - A helper killed by a signal, exiting with an error, or whose log shows a Vulkan error, while the GPU is in use:
//!   restarted; twice within 10 minutes (either helper), both start over on the CPU (DIGUP_GPU=0) for the rest of the
//!   session. Never saved: a reboot or a driver update may well fix it, and Settings offers "Try the GPU again".
//!   On the CPU, the index helper is restarted at most 3 times in 10 minutes, then left stopped.
//! - search-service's query encoder can't start on the GPU (`encoder` … `unavailable`): search-service starts over on
//!   the CPU, once; keyword search works meanwhile.
//!
//! The decisions are pure (`Health`), tested below with made-up times.

use std::path::Path;
use std::time::{Duration, Instant};

/// How far back failures count.
pub const WINDOW: Duration = Duration::from_secs(10 * 60);

/// The exit status of a helper its watchdog ended (`StoppedFile.exitCode` in Watchdog.swift: EX_TEMPFAIL).
pub const WATCHDOG_EXIT: i32 = 75;

/// Restarts allowed within `WINDOW` before giving up (watchdog stops, or crashes on the CPU).
const RESTARTS: usize = 3;

/// GPU failures within `WINDOW` that send the helpers to the CPU.
const GPU_FAILURES: usize = 2;

/// When things happened lately.
#[derive(Debug, Default)]
pub struct Recent(Vec<Instant>);

impl Recent {
    /// Notes one now; how many there were within `WINDOW`, this one too.
    pub fn note(&mut self, now: Instant) -> usize {
        self.0.retain(|then| now.saturating_duration_since(*then) < WINDOW);
        self.0.push(now);
        self.0.len()
    }

    pub fn clear(&mut self) {
        self.0.clear();
    }
}

/// How a helper ended.
#[derive(Debug, PartialEq)]
pub enum Ending {
    /// As it should: done, stopped by the shell, or an error it reported itself (a fatal "error" event).
    Fine,
    /// Its watchdog ended it on a file (exit 75).
    Watchdog,
    /// Killed by a signal, an error exit, or Vulkan trouble in its log: why, for the log.
    Failed(String),
}

/// How a helper ended: its exit `code` (None after a signal, or when the shell stopped it), the `signal` that ended it,
/// whether it said a fatal error first (`fatal`: it knew what went wrong, and said so), and a Vulkan error from its log.
pub fn ending(code: Option<i32>, signal: Option<i32>, fatal: bool, gpu_error: Option<&str>) -> Ending {
    if code.is_none() && signal.is_none() {
        return Ending::Fine;   // the shell stopped it
    }
    if code == Some(WATCHDOG_EXIT) {
        return Ending::Watchdog;
    }
    if let Some(line) = gpu_error {
        return Ending::Failed(format!("Vulkan: {line}"));
    }
    if let Some(signal) = signal {
        return Ending::Failed(format!("killed by {}", signal_name(signal)));
    }
    match code {
        Some(code) if code != 0 && !fatal => Ending::Failed(format!("exit code {code}")),
        _ => Ending::Fine,
    }
}

fn signal_name(signal: i32) -> String {
    match signal {
        4 => "SIGILL".into(),
        5 => "SIGTRAP".into(),
        6 => "SIGABRT".into(),
        7 => "SIGBUS".into(),
        9 => "SIGKILL".into(),
        11 => "SIGSEGV".into(),
        other => format!("signal {other}"),
    }
}

/// The first line of a helper's log that says the GPU failed: Vulkan's errors as ggml-vulkan and the Vulkan C++
/// bindings write them ("vk::DeviceLostError", "ErrorDeviceLost", "VK_ERROR_DEVICE_LOST").
pub fn gpu_error(log: &str) -> Option<String> {
    log.lines()
        .find(|line| line.contains("ErrorDeviceLost") || line.contains("vk::") || line.contains("VK_ERROR"))
        .map(|line| line.trim().chars().take(200).collect())
}

/// The file the index helper's watchdog stopped on, from `<index>/stopped-file.json` ({"path": …, "why": …}), read
/// before the next helper starts: that one takes the note away.
pub fn stopped_file(index: &Path) -> Option<(String, String)> {
    let note: serde_json::Value = serde_json::from_slice(&std::fs::read(index.join("stopped-file.json")).ok()?).ok()?;
    let path = note["path"].as_str()?.to_string();
    Some((path, note["why"].as_str().unwrap_or_default().to_string()))
}

/// What to do after a helper ended.
#[derive(Debug, PartialEq)]
pub enum Next {
    Nothing,
    /// Start the index helper again.
    Restart,
    /// The watchdog stopped on files too often: pause indexing.
    Pause,
    /// The GPU failed again: both helpers start over on the CPU.
    UseCpu,
    /// Crashed too often on the CPU too: leave indexing stopped.
    GiveUp,
}

/// What the shell knows of its helpers' troubles this session.
#[derive(Debug, Default)]
pub struct Health {
    watchdog_stops: Recent,
    gpu_failures: Recent,
    cpu_crashes: Recent,
    /// The GPU failed: every helper runs on the CPU until the shell quits or "Try the GPU again".
    pub on_cpu: bool,
    /// search-service's encoder couldn't start on the GPU, so it runs on the CPU (tried once a session).
    pub search_on_cpu: bool,
}

impl Health {
    /// After the index helper ended; `gpu`: it ran on the GPU.
    pub fn index_ended(&mut self, ending: &Ending, gpu: bool, now: Instant) -> Next {
        match ending {
            Ending::Fine => Next::Nothing,
            Ending::Watchdog if self.watchdog_stops.note(now) <= RESTARTS => Next::Restart,
            Ending::Watchdog => Next::Pause,
            Ending::Failed(_) => self.failed(gpu, now),
        }
    }

    /// After search-service ended (the next search starts it again by itself). A watchdog exit isn't one of its own.
    pub fn search_ended(&mut self, ending: &Ending, gpu: bool, now: Instant) -> Next {
        match ending {
            Ending::Failed(_) if gpu && self.gpu_failures.note(now) >= GPU_FAILURES => Next::UseCpu,
            _ => Next::Nothing,
        }
    }

    fn failed(&mut self, gpu: bool, now: Instant) -> Next {
        if gpu {
            if self.gpu_failures.note(now) >= GPU_FAILURES { Next::UseCpu } else { Next::Restart }
        } else if self.cpu_crashes.note(now) <= RESTARTS {
            Next::Restart
        } else {
            Next::GiveUp
        }
    }

    /// search-service said its encoder is unavailable: start it over on the CPU? Only from the GPU, once the model is
    /// in (before, there's no encoder anywhere), and once a session.
    pub fn encoder_unavailable(&mut self, gpu: bool, model_ready: bool) -> bool {
        if !gpu || !model_ready || self.search_on_cpu {
            return false;
        }
        self.search_on_cpu = true;
        true
    }

    /// "Try the GPU again": as at the start of the session.
    pub fn try_gpu_again(&mut self) {
        self.on_cpu = false;
        self.search_on_cpu = false;
        self.gpu_failures.clear();
        self.cpu_crashes.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minutes(start: Instant, minutes: u64) -> Instant {
        start + Duration::from_secs(minutes * 60)
    }

    #[test]
    fn how_helpers_end() {
        assert_eq!(ending(Some(0), None, false, None), Ending::Fine);
        assert_eq!(ending(None, None, false, None), Ending::Fine, "stopped by the shell");
        assert_eq!(ending(Some(1), None, true, None), Ending::Fine, "a fatal error it reported itself");
        assert_eq!(ending(Some(75), None, false, None), Ending::Watchdog);
        assert_eq!(ending(None, Some(6), false, None), Ending::Failed("killed by SIGABRT".into()));
        assert_eq!(ending(Some(1), None, false, None), Ending::Failed("exit code 1".into()));
        assert_eq!(ending(Some(0), None, false, Some("vk::Queue::submit: ErrorDeviceLost")),
                   Ending::Failed("Vulkan: vk::Queue::submit: ErrorDeviceLost".into()), "even when it exited fine");
        assert_eq!(ending(None, None, false, Some("vk::Queue::submit: ErrorDeviceLost")), Ending::Fine,
                   "one the shell stopped isn't counted");
    }

    #[test]
    fn vulkan_errors_in_a_log() {
        let log = "load_tensors: offloaded 25/25 layers to GPU\n\
                   terminate called after throwing an instance of 'vk::DeviceLostError'\n  what():  vk::Queue::submit: ErrorDeviceLost\n";
        assert_eq!(gpu_error(log).as_deref(), Some("terminate called after throwing an instance of 'vk::DeviceLostError'"));
        assert!(gpu_error("ggml_vulkan: Device memory allocation failed: VK_ERROR_OUT_OF_DEVICE_MEMORY").is_some());
        assert_eq!(gpu_error("ggml_vulkan: Found 1 Vulkan devices:\nwatchdog: took more than 15 minutes"), None);
    }

    #[test]
    fn the_watchdog_restarts_three_times_in_ten_minutes() {
        let (mut health, start) = (Health::default(), Instant::now());
        for minute in 0..3 {
            assert_eq!(health.index_ended(&Ending::Watchdog, true, minutes(start, minute)), Next::Restart);
        }
        assert_eq!(health.index_ended(&Ending::Watchdog, true, minutes(start, 4)), Next::Pause);
        // Ten minutes after the first ones, they no longer count.
        let mut health = Health::default();
        for minute in [0, 1, 2, 11] {
            assert_eq!(health.index_ended(&Ending::Watchdog, true, minutes(start, minute)), Next::Restart);
        }
        assert_eq!(health.index_ended(&Ending::Fine, true, minutes(start, 12)), Next::Nothing);
    }

    #[test]
    fn two_gpu_failures_in_ten_minutes_go_to_the_cpu() {
        let (mut health, start) = (Health::default(), Instant::now());
        let crash = Ending::Failed("killed by SIGSEGV".into());
        assert_eq!(health.index_ended(&crash, true, start), Next::Restart);
        assert_eq!(health.index_ended(&crash, true, minutes(start, 11)), Next::Restart, "the first one is too old");
        // Either helper's failures count.
        assert_eq!(health.search_ended(&crash, true, minutes(start, 12)), Next::UseCpu);
        // On the CPU: restarted three times, then left be.
        let mut health = Health { on_cpu: true, ..Health::default() };
        for minute in 0..3 {
            assert_eq!(health.index_ended(&crash, false, minutes(start, minute)), Next::Restart);
        }
        assert_eq!(health.index_ended(&crash, false, minutes(start, 3)), Next::GiveUp);
        assert_eq!(health.search_ended(&crash, false, start), Next::Nothing, "search starts again by itself");
        assert_eq!(health.search_ended(&Ending::Watchdog, true, start), Next::Nothing);
    }

    #[test]
    fn the_encoder_goes_to_the_cpu_once() {
        let mut health = Health::default();
        assert!(!health.encoder_unavailable(true, false), "no model yet: no encoder anywhere");
        assert!(!health.encoder_unavailable(false, true), "already on the CPU");
        assert!(health.encoder_unavailable(true, true));
        assert!(!health.encoder_unavailable(true, true), "once");
        health.on_cpu = true;
        health.try_gpu_again();
        assert!(!health.on_cpu && !health.search_on_cpu);
        assert!(health.encoder_unavailable(true, true), "again after Try the GPU again");
    }

    #[test]
    fn the_file_the_watchdog_stopped_on() {
        let folder = std::env::temp_dir().join(format!("digup-fallback-test-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        assert_eq!(stopped_file(&folder), None);
        std::fs::write(folder.join("stopped-file.json"),
                       r#"{"path":"/home/me/Big.pdf","why":"took more than 15 minutes to read"}"#).unwrap();
        assert_eq!(stopped_file(&folder),
                   Some(("/home/me/Big.pdf".into(), "took more than 15 minutes to read".into())));
        let _ = std::fs::remove_dir_all(folder);
    }
}
