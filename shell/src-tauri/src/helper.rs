//! DigUp's helper processes, which do all the work: `digup search-service` answers the panel (a JSON request per line
//! in, the reply on a line out with the request's id; lines without an id are events), and `digup index-service` keeps
//! the index current (commands in, events out) and exits when it's done. Sources/digup has both protocols.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;

type EventSink = Arc<dyn Fn(Value) + Send + Sync>;

/// How a helper is started.
#[derive(Clone)]
pub struct Launch {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    /// Where its standard error goes (llama.cpp and the helper write their warnings there).
    pub log: Option<PathBuf>,
    /// Work in the background (indexing, the download): below the person's own programs for the processor.
    pub background: bool,
}

impl Launch {
    fn spawn(&self) -> Result<(Child, ChildStdin, ChildStdout), String> {
        let mut command = Command::new(&self.program);
        command
            .args(&self.args)
            .envs(self.env.iter().map(|(key, value)| (key, value)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(match self.log.as_ref().and_then(|path| OpenOptions::new().create(true).append(true).open(path).ok()) {
                Some(file) => Stdio::from(file),
                None => Stdio::null(),
            });
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            // CREATE_NO_WINDOW (no console flashes up), and BELOW_NORMAL_PRIORITY_CLASS for background work.
            command.creation_flags(0x0800_0000 | if self.background { 0x0000_4000 } else { 0 });
        }
        #[cfg(unix)]
        if self.background {
            use std::os::unix::process::CommandExt;
            // SAFETY: nice() only changes the new process's own priority, between fork and exec.
            unsafe {
                command.pre_exec(|| {
                    libc::nice(10);
                    Ok(())
                });
            }
        }
        let mut child = command.spawn().map_err(|error| format!("can't start {}: {error}", self.program.display()))?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        Ok((child, stdin, stdout))
    }
}

/// Asks the process to stop (`farewell` on stdin, then stdin closed), and ends it if it hasn't within two seconds.
fn stop(mut child: Child, mut stdin: ChildStdin, farewell: &str) {
    let _ = writeln!(stdin, "{farewell}").and_then(|_| stdin.flush());
    drop(stdin);
    for _ in 0..40 {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// A helper's process, shared with the thread that reads its output: that thread waits for it once the output ends,
/// so a helper that's done doesn't stay a zombie (`<defunct>`) until the next one starts. `take` hands it to `stop`.
#[derive(Clone)]
struct Process(Arc<Mutex<Option<Child>>>);

impl Process {
    fn new(child: Child) -> Process {
        Process(Arc::new(Mutex::new(Some(child))))
    }

    /// It hasn't exited (and hasn't been taken to be stopped).
    fn is_running(&self) -> bool {
        self.0.lock().unwrap().as_mut().is_some_and(|child| matches!(child.try_wait(), Ok(None)))
    }

    fn take(&self) -> Option<Child> {
        self.0.lock().unwrap().take()
    }

    /// Once its output has ended: waits for it to exit and says how (its exit code; None after a signal, or when
    /// `stop` took it meanwhile). It asks now and then rather than blocking in `wait`, which would hold the lock that
    /// `stop` and `is_running` need: a process can close its output a while before it exits.
    fn reap(&self) -> Option<i32> {
        let mut pause = Duration::from_millis(10);
        loop {
            match self.0.lock().unwrap().as_mut()?.try_wait() {
                Ok(Some(status)) => return status.code(),
                Ok(None) => {}
                Err(_) => return None,
            }
            std::thread::sleep(pause);
            pause = (pause * 2).min(Duration::from_secs(1));
        }
    }

    #[cfg(test)]
    fn id(&self) -> Option<u32> {
        self.0.lock().unwrap().as_ref().map(Child::id)
    }
}

/// `digup search-service`: started on the first request, and again after it died.
pub struct SearchService {
    /// How the next one starts (the folders and the GPU switch change it).
    launch: Mutex<Launch>,
    running: Mutex<Option<Searching>>,
    next_id: AtomicU64,
    on_event: EventSink,
}

struct Searching {
    process: Process,
    stdin: ChildStdin,
    /// Replies still to come, by request id. Each process has its own, so one that dies fails only its own requests.
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
}

impl SearchService {
    pub fn new(launch: Launch, on_event: impl Fn(Value) + Send + Sync + 'static) -> SearchService {
        SearchService {
            launch: Mutex::new(launch),
            running: Mutex::new(None),
            next_id: AtomicU64::new(1),
            on_event: Arc::new(on_event),
        }
    }

    /// How it starts from now on: the running one keeps going (it's told new folders over its stdin); one that dies,
    /// or is stopped to take a new environment, starts this way.
    pub fn set_launch(&self, launch: Launch) {
        *self.launch.lock().unwrap() = launch;
    }

    /// Sends a request and waits for its reply.
    pub async fn ask(&self, mut request: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        request["id"] = json!(id);
        let reply = self.send(id, &request)?;
        let reply = reply.await.map_err(|_| "DigUp's helper stopped".to_string())?;
        match reply.get("ok") {
            Some(Value::Bool(false)) => Err(reply["error"].as_str().unwrap_or("the helper failed").to_string()),
            _ => Ok(reply),
        }
    }

    fn send(&self, id: u64, request: &Value) -> Result<oneshot::Receiver<Value>, String> {
        let mut running = self.running.lock().unwrap();
        if let Some(searching) = running.as_mut() {
            if !searching.process.is_running() {
                *running = None;
            }
        }
        if running.is_none() {
            *running = Some(self.start()?);
        }
        let searching = running.as_mut().unwrap();
        let (sender, receiver) = oneshot::channel();
        searching.pending.lock().unwrap().insert(id, sender);
        if let Err(error) = writeln!(searching.stdin, "{request}").and_then(|_| searching.stdin.flush()) {
            searching.pending.lock().unwrap().remove(&id);
            *running = None;
            return Err(format!("DigUp's helper isn't answering: {error}"));
        }
        Ok(receiver)
    }

    fn start(&self) -> Result<Searching, String> {
        let launch = self.launch.lock().unwrap().clone();
        let (child, stdin, stdout) = launch.spawn()?;
        let process = Process::new(child);
        let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>> = Arc::default();
        let (replies, on_event, reaped) = (pending.clone(), self.on_event.clone(), process.clone());
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                match message.get("id").and_then(Value::as_u64) {
                    Some(id) => {
                        if let Some(sender) = replies.lock().unwrap().remove(&id) {
                            let _ = sender.send(message);
                        }
                    }
                    None => on_event(message),
                }
            }
            // Gone: its waiting requests fail (their senders drop here), and the next request starts another.
            replies.lock().unwrap().clear();
            reaped.reap();
            on_event(json!({"event": "exit"}));
        });
        Ok(Searching { process, stdin, pending })
    }

    pub fn stop(&self) {
        if let Some(searching) = self.running.lock().unwrap().take() {
            if let Some(child) = searching.process.take() {
                stop(child, searching.stdin, &json!({"op": "quit"}).to_string());
            }
        }
    }
}

/// `digup index-service`: syncs the index with the folders, indexes what's new, and exits once it's done. `run` starts
/// it, asks the running one to sync again, or, when the folders changed (another launch), starts it over with them.
pub struct IndexService {
    running: Mutex<Option<(Process, ChildStdin, Vec<String>)>>,
    on_event: EventSink,
}

impl IndexService {
    pub fn new(on_event: impl Fn(Value) + Send + Sync + 'static) -> IndexService {
        IndexService { running: Mutex::new(None), on_event: Arc::new(on_event) }
    }

    pub fn run(&self, launch: &Launch) -> Result<(), String> {
        let mut running = self.running.lock().unwrap();
        if let Some((process, stdin, args)) = running.as_mut() {
            if process.is_running() {
                if *args == launch.args {
                    return writeln!(stdin, "sync").and_then(|_| stdin.flush()).map_err(|error| error.to_string());
                }
                let (process, stdin, _) = running.take().unwrap();
                if let Some(child) = process.take() {
                    stop(child, stdin, "stop");
                }
            }
        }
        let (child, stdin, stdout) = launch.spawn()?;
        let process = Process::new(child);
        let (on_event, reaped) = (self.on_event.clone(), process.clone());
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if let Ok(event) = serde_json::from_str::<Value>(&line) {
                    on_event(event);
                }
            }
            reaped.reap();
            on_event(json!({"event": "exit"}));
        });
        *running = Some((process, stdin, launch.args.clone()));
        Ok(())
    }

    pub fn stop(&self) {
        if let Some((process, stdin, _)) = self.running.lock().unwrap().take() {
            if let Some(child) = process.take() {
                stop(child, stdin, "stop");
            }
        }
    }
}

/// `digup download-model`: the model files, from the Hugging Face cache or downloaded with resume, each checked. One at
/// a time; `run` again while it runs does nothing. Its events ("progress", "done", "error"…) go to `on_event`.
pub struct ModelDownload {
    running: Mutex<Option<Process>>,
    on_event: EventSink,
}

impl ModelDownload {
    pub fn new(on_event: impl Fn(Value) + Send + Sync + 'static) -> ModelDownload {
        ModelDownload { running: Mutex::new(None), on_event: Arc::new(on_event) }
    }

    pub fn run(&self, launch: &Launch) -> Result<(), String> {
        let mut running = self.running.lock().unwrap();
        if running.as_ref().is_some_and(Process::is_running) {
            return Ok(());
        }
        let (child, stdin, stdout) = launch.spawn()?;
        drop(stdin);
        let process = Process::new(child);
        let (on_event, reaped) = (self.on_event.clone(), process.clone());
        std::thread::spawn(move || {
            let mut ended = false;
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if let Ok(event) = serde_json::from_str::<Value>(&line) {
                    ended |= event["event"] == "done" || event["event"] == "error";
                    on_event(event);
                }
            }
            reaped.reap();
            if !ended {
                on_event(json!({"event": "error", "message": "the download stopped"}));
            }
        });
        *running = Some(process);
        Ok(())
    }

    pub fn stop(&self) {
        if let Some(mut child) = self.running.lock().unwrap().take().and_then(|process| process.take()) {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::path::Path;
    use std::time::Instant;

    /// A stand-in for `digup`: a shell script that logs each line it's sent (to `$FAKE_LOG`) and behaves as
    /// `$FAKE_MODE` says. "serve": a sync event at the start and one for each "sync", exits on "stop" or EOF.
    /// "quit": a sync event and an exit event, then exits at once (a helper with nothing to do).
    pub(super) fn fake_helper(folder: &Path, mode: &str) -> Launch {
        std::fs::create_dir_all(folder).unwrap();
        let script = folder.join("fake-digup");
        std::fs::write(&script, r#"#!/bin/sh
synced() { echo "{\"event\": \"sync\", \"started\": $(date +%s.%N)}"; }
echo "start $*" >> "$FAKE_LOG"
synced
case "$FAKE_MODE" in
quit) echo '{"event": "exit"}'; exit 0 ;;
esac
while read -r line; do
    echo "$line" >> "$FAKE_LOG"
    case "$line" in
    sync) synced ;;
    stop) echo '{"event": "exit"}'; exit 0 ;;
    esac
done
"#).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        Launch {
            program: script,
            args: vec!["index-service".into(), "/a".into()],
            env: vec![("FAKE_LOG".into(), folder.join("log").display().to_string()), ("FAKE_MODE".into(), mode.into())],
            log: None,
            background: false,
        }
    }

    pub(super) fn folder(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("digup-helper-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        folder
    }

    pub(super) fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
        let started = Instant::now();
        while !done() {
            assert!(started.elapsed() < Duration::from_secs(10), "waited too long for {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    pub(super) fn log(folder: &Path) -> Vec<String> {
        std::fs::read_to_string(folder.join("log")).unwrap_or_default().lines().map(String::from).collect()
    }

    /// The process is gone for good: not even a zombie waiting to be reaped.
    fn reaped(pid: u32) -> bool {
        // SAFETY: signal 0 only asks whether the process exists.
        unsafe { libc::kill(pid as i32, 0) != 0 }
    }

    fn events() -> (Arc<Mutex<Vec<Value>>>, impl Fn(Value) + Send + Sync + 'static) {
        let seen: Arc<Mutex<Vec<Value>>> = Arc::default();
        let sink = seen.clone();
        (seen, move |event| sink.lock().unwrap().push(event))
    }

    #[test]
    fn a_running_helper_is_asked_to_sync_and_new_folders_start_another() {
        let folder = folder("sync");
        let launch = fake_helper(&folder, "serve");
        let (seen, sink) = events();
        let service = IndexService::new(sink);
        service.run(&launch).unwrap();
        wait_for("its first sync", || seen.lock().unwrap().iter().any(|event| event["event"] == "sync"));
        service.run(&launch).unwrap();
        wait_for("the sync it was sent", || log(&folder).contains(&"sync".to_string()));
        assert_eq!(log(&folder).iter().filter(|line| line.starts_with("start")).count(), 1, "the same helper");
        let mut other = launch.clone();
        other.args.push("/b".into());
        service.run(&other).unwrap();
        wait_for("the new helper", || log(&folder).iter().filter(|line| line.starts_with("start")).count() == 2);
        assert_eq!(log(&folder), ["start index-service /a", "sync", "stop", "start index-service /a /b"]);
        service.stop();
        let _ = std::fs::remove_dir_all(folder);
    }

    #[test]
    fn helpers_that_are_done_are_reaped() {
        let folder = folder("reap");
        let launch = fake_helper(&folder, "quit");
        let (seen, sink) = events();
        let service = IndexService::new(sink);
        service.run(&launch).unwrap();
        let pid = service.running.lock().unwrap().as_ref().unwrap().0.id().unwrap();
        wait_for("its exit", || seen.lock().unwrap().iter().filter(|event| event["event"] == "exit").count() == 2);
        assert!(reaped(pid), "no <defunct> left behind");
        // The next run starts another one rather than writing to the one that's gone.
        service.run(&launch).unwrap();
        wait_for("the second helper", || log(&folder).len() == 2);
        assert_eq!(log(&folder), ["start index-service /a", "start index-service /a"]);

        let download = ModelDownload::new(|_| {});
        download.run(&launch).unwrap();
        let pid = download.running.lock().unwrap().as_ref().unwrap().id().unwrap();
        wait_for("the download to be reaped", || reaped(pid));

        let search = SearchService::new(launch.clone(), |_| {});
        let _ = search.send(1, &json!({"op": "status"}));
        let pid = search.running.lock().unwrap().as_ref().unwrap().process.id().unwrap();
        wait_for("the search service to be reaped", || reaped(pid));
        let _ = std::fs::remove_dir_all(folder);
    }
}
