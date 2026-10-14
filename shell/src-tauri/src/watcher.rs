//! Watching the chosen folders: a change anywhere in them asks the index helper to sync, two seconds after the last one
//! (a camera import or an unzip is a burst of events). `notify` uses ReadDirectoryChangesW on Windows, inotify on Linux,
//! FSEvents on a Mac. Changes in DigUp's own index folder are passed over.

use notify::{RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

pub struct FolderWatcher {
    _watcher: Option<notify::RecommendedWatcher>,
}

impl FolderWatcher {
    /// Watches `folders`; `changed` runs on the watcher's own thread after each burst of changes. Dropping it stops.
    pub fn start(folders: &[PathBuf], ignore: Option<PathBuf>, changed: impl Fn() + Send + 'static) -> FolderWatcher {
        let (sender, receiver) = mpsc::channel::<()>();
        let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            if event.kind.is_access() {
                return;
            }
            let ours = |path: &PathBuf| ignore.as_ref().is_some_and(|folder| path.starts_with(folder));
            if event.paths.is_empty() || !event.paths.iter().all(ours) {
                let _ = sender.send(());
            }
        });
        let mut watcher = match watcher {
            Ok(watcher) => watcher,
            Err(error) => {
                eprintln!("digup-shell: can't watch folders: {error}");
                return FolderWatcher { _watcher: None };
            }
        };
        for folder in folders {
            if let Err(error) = watcher.watch(folder, RecursiveMode::Recursive) {
                eprintln!("digup-shell: can't watch {}: {error}", folder.display());
            }
        }
        std::thread::spawn(move || {
            while receiver.recv().is_ok() {
                while receiver.recv_timeout(Duration::from_secs(2)).is_ok() {}
                changed();
            }
        });
        FolderWatcher { _watcher: Some(watcher) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Instant;

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
        let changes = Arc::new(AtomicUsize::new(0));
        let counted = changes.clone();
        let _watcher = FolderWatcher::start(std::slice::from_ref(&root), Some(index.clone()), move || {
            counted.fetch_add(1, Ordering::SeqCst);
        });
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
}
