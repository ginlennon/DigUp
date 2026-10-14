//! Watching the chosen folders: a change anywhere in them asks the index helper to sync, two seconds after the last one
//! (a camera import or an unzip is a burst of events). `notify` uses ReadDirectoryChangesW on Windows, inotify on Linux,
//! FSEvents on a Mac. Changes in DigUp's own index folder are passed over.
//!
//! The code folders (code search) too, as the Mac app watches them (Engine.swift's `codeChanged`): code that's being
//! worked on changes on every save, a branch switch or a build changes many files at once, so the code index catches up
//! ("sync code") once code has been quiet for a minute, or every ten minutes while it keeps changing. Changes code
//! search never reads (hidden folders such as .git, builds, dependencies: `CODE_NOISE`) don't count. Code folders are
//! watched folder by folder, leaving those out: on inotify each folder costs a watch, and a repo's node_modules or
//! target folder alone can have tens of thousands.

use notify::{RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex, Weak};
use std::time::{Duration, Instant};

/// Folders whose changes don't concern the code index (what code search leaves out by name, as the Mac app's
/// `codeNoise`).
const CODE_NOISE: &[&str] = &[
    "node_modules", "bower_components", "venv", "site-packages", "__pycache__", "DerivedData", "Pods", "Carthage",
    "vendor", "Vendor", "third_party", "build", "Build", "dist", "out", "target", "obj", "coverage", "wandb", "mlruns",
    "lightning_logs",
];

/// The most folders watched in the code folders: past this, changes deeper in aren't seen until the next sync (an
/// inotify watch each; the system's limit, fs.inotify.max_user_watches, is often 65,536 for everything).
const CODE_WATCHES: usize = 30_000;

/// How long changes settle before a sync.
#[derive(Clone, Copy)]
pub struct Timing {
    /// The chosen folders: after the last change of a burst.
    pub settle: Duration,
    /// Code: after the last change…
    pub code_quiet: Duration,
    /// …or this long after the first one, while it keeps changing.
    pub code_longest: Duration,
}

pub const TIMING: Timing = Timing {
    settle: Duration::from_secs(2),
    code_quiet: Duration::from_secs(60),
    code_longest: Duration::from_secs(600),
};

/// What a changed path asks for.
#[derive(Debug, PartialEq)]
pub enum Change {
    /// A sync of the chosen folders.
    Files,
    /// A sync of the code index.
    Code,
    /// Nothing: DigUp's own index, or what code search doesn't read.
    Nothing,
}

/// What a change at `path` asks for: code under a code folder (unless it's in a hidden or noise folder there), else
/// files, except in the index folder (`ignore`).
pub fn classify(path: &Path, code_roots: &[PathBuf], ignore: Option<&Path>) -> Change {
    if ignore.is_some_and(|folder| path.starts_with(folder)) {
        return Change::Nothing;
    }
    let Some(root) = code_roots.iter().find(|root| path.starts_with(root)) else { return Change::Files };
    let inside = path.strip_prefix(root).unwrap_or(path);
    if inside.components().any(|part| is_noise(&part.as_os_str().to_string_lossy())) {
        return Change::Nothing;
    }
    Change::Code
}

fn is_noise(name: &str) -> bool {
    name.starts_with('.') || CODE_NOISE.contains(&name)
}

pub struct FolderWatcher {
    _watcher: Option<Arc<Mutex<notify::RecommendedWatcher>>>,
}

impl FolderWatcher {
    /// Watches `folders` and the `code` folders; `changed` runs on a thread of the watcher's own after each burst of
    /// changes in the folders, `code_changed` once code has been quiet (`TIMING`). Dropping it stops.
    pub fn start(folders: &[PathBuf], code: &[PathBuf], ignore: Option<PathBuf>, changed: impl Fn() + Send + 'static,
                 code_changed: impl Fn() + Send + 'static) -> FolderWatcher {
        FolderWatcher::start_with(folders, code, ignore, changed, code_changed, TIMING)
    }

    fn start_with(folders: &[PathBuf], code: &[PathBuf], ignore: Option<PathBuf>, changed: impl Fn() + Send + 'static,
                  code_changed: impl Fn() + Send + 'static, timing: Timing) -> FolderWatcher {
        let (files_sender, files) = mpsc::channel::<()>();
        // Code changes, with the folders made in the code folders (to be watched too).
        let (code_sender, code_changes) = mpsc::channel::<Vec<PathBuf>>();
        let code_roots = code.to_vec();
        let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            if event.kind.is_access() {
                return;
            }
            let (mut files, mut code) = (event.paths.is_empty(), false);
            for path in &event.paths {
                match classify(path, &code_roots, ignore.as_deref()) {
                    Change::Files => files = true,
                    Change::Code => code = true,
                    Change::Nothing => {}
                }
            }
            if files {
                let _ = files_sender.send(());
            }
            if code {
                let made = if event.kind.is_create() { event.paths.iter().filter(|path| path.is_dir()).cloned().collect() }
                           else { Vec::new() };
                let _ = code_sender.send(made);
            }
        });
        let watcher = match watcher {
            Ok(watcher) => Arc::new(Mutex::new(watcher)),
            Err(error) => {
                log_error!("digup-shell: can't watch folders: {error}");
                return FolderWatcher { _watcher: None };
            }
        };
        for folder in folders {
            if let Err(error) = watcher.lock().unwrap().watch(folder, RecursiveMode::Recursive) {
                log_error!("digup-shell: can't watch {}: {error}", folder.display());
            }
        }
        let mut watches = 0;
        for folder in code {
            watch_code(&watcher, folder, &mut watches);
        }
        std::thread::spawn(move || {
            while files.recv().is_ok() {
                while files.recv_timeout(timing.settle).is_ok() {}
                changed();
            }
        });
        // The thread holds the watcher weakly: once the FolderWatcher is dropped, the watcher goes, its channels close
        // and the threads end.
        let weak = Arc::downgrade(&watcher);
        std::thread::spawn(move || {
            while let Ok(made) = code_changes.recv() {
                let first = Instant::now();
                watch_new(&weak, made, &mut watches);
                // Until it's been quiet for `code_quiet`, or `code_longest` since the first change.
                loop {
                    let left = timing.code_longest.saturating_sub(first.elapsed());
                    match code_changes.recv_timeout(timing.code_quiet.min(left)) {
                        Ok(made) => watch_new(&weak, made, &mut watches),
                        Err(mpsc::RecvTimeoutError::Timeout) => break,
                        Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    }
                }
                code_changed();
            }
        });
        FolderWatcher { _watcher: Some(watcher) }
    }
}

fn watch_new(watcher: &Weak<Mutex<notify::RecommendedWatcher>>, made: Vec<PathBuf>, watches: &mut usize) {
    if made.is_empty() {
        return;
    }
    if let Some(watcher) = watcher.upgrade() {
        for folder in made {
            watch_code(&watcher, &folder, watches);
        }
    }
}

/// Watches a code folder and the folders in it, one by one, leaving out hidden ones and noise (`CODE_NOISE`), up to
/// `CODE_WATCHES` in all. Links aren't followed (a link to a folder outside would be watched twice or forever).
fn watch_code(watcher: &Mutex<notify::RecommendedWatcher>, root: &Path, watches: &mut usize) {
    let mut waiting = vec![root.to_path_buf()];
    while let Some(folder) = waiting.pop() {
        if *watches >= CODE_WATCHES {
            log_error!("digup-shell: watching {CODE_WATCHES} code folders, no more: changes deeper in {} wait for the \
                        next sync", root.display());
            return;
        }
        if watcher.lock().unwrap().watch(&folder, RecursiveMode::NonRecursive).is_err() {
            continue;
        }
        *watches += 1;
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        for entry in entries.filter_map(Result::ok) {
            let is_folder = entry.file_type().is_ok_and(|kind| kind.is_dir());
            if is_folder && !is_noise(&entry.file_name().to_string_lossy()) {
                waiting.push(entry.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn wait_until(seconds: u64, mut done: impl FnMut() -> bool) -> bool {
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(seconds) {
            if done() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        done()
    }

    fn counter() -> (Arc<AtomicUsize>, impl Fn() + Send + 'static) {
        let count = Arc::new(AtomicUsize::new(0));
        let counted = count.clone();
        (count, move || {
            counted.fetch_add(1, Ordering::SeqCst);
        })
    }

    /// A file copied in while lots else goes on (files read, DigUp's own index folder written) is seen, and what
    /// happens only in the index folder or is only reading isn't.
    #[test]
    fn a_copy_is_seen_among_other_events() {
        let root = std::env::temp_dir().join(format!("digup-watcher-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (videos, index) = (root.join("Videos"), root.join("index"));
        std::fs::create_dir_all(&videos).unwrap();
        std::fs::create_dir_all(&index).unwrap();
        for number in 0..200 {
            std::fs::write(videos.join(format!("old {number}.txt")), "old").unwrap();
        }
        let (changes, changed) = counter();
        let _watcher = FolderWatcher::start(std::slice::from_ref(&root), &[], Some(index.clone()), changed, || {});
        std::thread::sleep(Duration::from_millis(300));

        // Reading the folder's files and writing the index: nothing to sync.
        for round in 0..5 {
            for number in 0..200 {
                let _ = std::fs::read(videos.join(format!("old {number}.txt")));
                std::fs::write(index.join(format!("chunk {round} {number}")), "x").unwrap();
            }
        }
        std::thread::sleep(Duration::from_millis(2600));
        assert_eq!(changes.load(Ordering::SeqCst), 0, "reads and the index folder don't count");

        // A copy among more of the same, as `cp some.mp4 ~/Videos/` during an indexing pass.
        let noise = {
            let (videos, index) = (videos.clone(), index.clone());
            std::thread::spawn(move || {
                for number in 0..2000 {
                    let _ = std::fs::read(videos.join(format!("old {}.txt", number % 200)));
                    std::fs::write(index.join(format!("more {number}")), "x").unwrap();
                }
            })
        };
        std::fs::write(videos.join("new.mp4"), vec![0u8; 4 << 20]).unwrap();
        noise.join().unwrap();
        assert!(wait_until(6, || changes.load(Ordering::SeqCst) == 1), "the copy asks for one sync");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn what_changes_ask_for() {
        let code = [PathBuf::from("/home/me/git")];
        let index = Some(Path::new("/home/me/.local/share/digup/index"));
        let change = |path: &str| classify(Path::new(path), &code, index);
        assert_eq!(change("/home/me/Documents/a.pdf"), Change::Files);
        assert_eq!(change("/home/me/git/app/src/main.rs"), Change::Code);
        assert_eq!(change("/home/me/git/app/.git/index"), Change::Nothing, "git's own files");
        assert_eq!(change("/home/me/git/app/node_modules/x/index.js"), Change::Nothing);
        assert_eq!(change("/home/me/git/app/target/debug/app"), Change::Nothing);
        assert_eq!(change("/home/me/.local/share/digup/index/index.sqlite"), Change::Nothing);
        // Noise is only noise inside a code folder: a "build" folder of photos is searched as ever.
        assert_eq!(change("/home/me/Pictures/build/a.jpg"), Change::Files);
    }

    /// Code changes wait until code has been quiet (made short here), noise doesn't count, and a folder made in a
    /// code folder is watched too.
    #[test]
    fn code_changes_wait_until_its_quiet() {
        let root = std::env::temp_dir().join(format!("digup-code-watcher-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let repo = root.join("repo");
        std::fs::create_dir_all(repo.join("src")).unwrap();
        std::fs::create_dir_all(repo.join("target/debug")).unwrap();
        let (files, changed) = counter();
        let (code, code_changed) = counter();
        let timing = Timing { settle: Duration::from_millis(100), code_quiet: Duration::from_millis(400),
                              code_longest: Duration::from_secs(30) };
        let _watcher = FolderWatcher::start_with(&[], std::slice::from_ref(&repo), None, changed, code_changed, timing);
        std::thread::sleep(Duration::from_millis(200));

        std::fs::write(repo.join("target/debug/app"), "built").unwrap();
        std::thread::sleep(Duration::from_millis(800));
        assert_eq!(code.load(Ordering::SeqCst), 0, "a build doesn't count");

        // Saves every 100 ms: one sync, after they stop.
        for number in 0..6 {
            std::fs::write(repo.join("src/main.rs"), format!("fn main() {{}} // {number}")).unwrap();
            std::thread::sleep(Duration::from_millis(100));
            assert_eq!(code.load(Ordering::SeqCst), 0, "not while it's being edited");
        }
        assert!(wait_until(5, || code.load(Ordering::SeqCst) == 1), "once it's quiet");

        // A new folder, and a file in it a moment later.
        std::fs::create_dir_all(repo.join("tests")).unwrap();
        assert!(wait_until(5, || code.load(Ordering::SeqCst) == 2));
        std::fs::write(repo.join("tests/it.rs"), "#[test] fn it() {}").unwrap();
        assert!(wait_until(5, || code.load(Ordering::SeqCst) == 3), "the new folder is watched");
        assert_eq!(files.load(Ordering::SeqCst), 0, "code isn't a sync of the chosen folders");
        let _ = std::fs::remove_dir_all(root);
    }
}
