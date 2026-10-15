//! Adding a folder on the spot (PLANS/FOLDERS_PLAN.md, A3): from the panel's "Add a folder…", Files' "DigUp: Add
//! this folder", or `digup-shell --add-folder DIR`. The add window (add.js) shows what DigUp makes of the folder
//! (`look`):
//! - one it won't take: the whole computer, the home folder itself or one that holds it, a system folder;
//! - one inside a folder it searches already: nothing to index, it only becomes the panel's scope (and skipped folders
//!   in it can be taken in);
//! - a git repo: it goes into the code index (code search), and into the documents' too if asked;
//! - any other: a new folder, with the subfolders the person leaves out skipped.
//!
//! `apply` puts the choice into the settings, where the folder stays like any other (Settings → Folders or Code
//! takes it out again). The shell then has its files indexed first, once (`--first`, IndexService.swift).

use crate::settings::Settings;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// The system's own folders: never added, nor anything in them. Drives mounted under /run/media are the person's.
const SYSTEM: &[&str] = &["/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64", "/libx32", "/lost+found", "/opt",
                          "/proc", "/root", "/run", "/sbin", "/snap", "/sys", "/usr", "/var"];
const MOUNTS: &str = "/run/media";

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// Not added (`Look::refused` says why).
    Refused,
    /// Indexed from now on as documents.
    New,
    /// A git repo: indexed from now on in the code index.
    Repo,
    /// Searched already: it becomes the scope.
    Inside,
}

/// What DigUp makes of a folder to add.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Look {
    pub path: String,
    pub name: String,
    pub kind: Kind,
    /// Why it isn't added.
    pub refused: Option<String>,
    /// It's (to be) in the code index: a repo, or a folder inside a code folder.
    pub code: bool,
    /// A repo that's searched as documents already (it's in a document folder): "also as documents" has nothing to add.
    pub documents: bool,
    /// `Inside`: the folder searched that it's in.
    pub within: Option<String>,
    /// `Inside`: the folders skipped in it (in that folder's index), which can be taken in.
    pub skipped: Vec<String>,
}

/// What the person chose in the add window.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Choice {
    /// `New`, `Repo`: its subfolders left out.
    pub skipped: Vec<String>,
    /// `Repo`: also searched as documents.
    pub documents: bool,
    /// `Inside`: the skipped folders taken in.
    pub take_in: Vec<String>,
}

/// What DigUp makes of `folder` (absolute, its links resolved) with these settings. `home` is the home folder;
/// `is_dir` and `exists` look at the disk (tests make them up).
pub fn look(folder: &Path, settings: &Settings, home: Option<&Path>, is_dir: impl Fn(&Path) -> bool,
            exists: impl Fn(&Path) -> bool) -> Look {
    let name = folder.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    let mut look = Look { path: folder.display().to_string(), name, kind: Kind::Refused, refused: None, code: false,
                          documents: false, within: None, skipped: Vec::new() };
    if let Some(why) = refused(folder, home, &is_dir) {
        look.refused = Some(why);
        return look;
    }
    let repo = exists(&folder.join(".git"));
    let documents = searched_in(folder, &settings.folders, &settings.skipped);
    let code = searched_in(folder, &settings.code_folders, &settings.code_skipped);
    // A folder searched as documents is a scope for any query; one in a code folder for code: queries. A repo goes to
    // the code index unless it's there already (as documents only its screenshots are read: code projects).
    let within = match (repo, documents.clone(), code) {
        (false, Some(root), _) => Some((root, false)),
        (_, _, Some(root)) => Some((root, true)),
        _ => None,
    };
    match within {
        Some((root, code)) => {
            let skips = if code { &settings.code_skipped } else { &settings.skipped };
            look.kind = Kind::Inside;
            look.code = code;
            look.skipped = skips.iter().filter(|skip| inside(Path::new(skip.as_str()), folder)).cloned().collect();
            look.within = Some(root);
        }
        None if repo => {
            look.kind = Kind::Repo;
            look.code = true;
            look.documents = documents.is_some();
        }
        None => look.kind = Kind::New,
    }
    look
}

/// Why `folder` isn't added, if it isn't.
fn refused(folder: &Path, home: Option<&Path>, is_dir: impl Fn(&Path) -> bool) -> Option<String> {
    let shown = folder.display();
    if !is_dir(folder) {
        return Some(format!("There's no folder at {shown}."));
    }
    if folder.parent().is_none() {
        return Some("DigUp doesn't index the whole computer: choose a folder you keep things in.".into());
    }
    if let Some(home) = home {
        if folder == home {
            return Some("That's your whole home folder, too much to index at once: choose the folders in it that you \
                         keep things in.".into());
        }
        if home.starts_with(folder) {
            return Some(format!("{shown} holds your home folder and more: choose a folder you keep things in."));
        }
    }
    if SYSTEM.iter().any(|system| folder.starts_with(system)) && !folder.starts_with(MOUNTS) {
        return Some(format!("{shown} is one of the system's folders: DigUp searches your own files."));
    }
    None
}

/// The closest of `folders` that searches `path` (it's that folder or inside it, and not in a folder skipped there),
/// as the engine's `FolderSelection` has it.
fn searched_in(path: &Path, folders: &[String], skipped: &[String]) -> Option<String> {
    folders.iter()
        .filter(|folder| {
            let folder = Path::new(folder.as_str());
            path.starts_with(folder) && !skipped.iter().any(|skip| {
                let skip = Path::new(skip.as_str());
                inside(skip, folder) && path.starts_with(skip)
            })
        })
        .max_by_key(|folder| folder.len())
        .cloned()
}

/// `path` is inside `folder`, not the folder itself.
fn inside(path: &Path, folder: &Path) -> bool {
    path != folder && path.starts_with(folder)
}

/// Puts the choice into the settings. True when there's something new to index.
pub fn apply(settings: &mut Settings, look: &Look, choice: &Choice) -> bool {
    let folder = Path::new(&look.path);
    let ours = |skip: &&String| inside(Path::new(skip.as_str()), folder);
    match look.kind {
        Kind::Refused => false,
        Kind::Inside => {
            let skipped = if look.code { &mut settings.code_skipped } else { &mut settings.skipped };
            let before = skipped.len();
            skipped.retain(|skip| !(choice.take_in.contains(skip) && look.skipped.contains(skip)));
            skipped.len() != before
        }
        Kind::New => {
            add_documents(settings, &look.path);
            for skip in choice.skipped.iter().filter(ours) {
                push(&mut settings.skipped, skip);
            }
            true
        }
        Kind::Repo => {
            push(&mut settings.code_folders, &look.path);
            for skip in choice.skipped.iter().filter(ours) {
                push(&mut settings.code_skipped, skip);
            }
            if choice.documents && !look.documents {
                add_documents(settings, &look.path);
                for skip in choice.skipped.iter().filter(ours) {
                    push(&mut settings.skipped, skip);
                }
            }
            true
        }
    }
}

/// A folder searched as documents from now on: one that was skipped stops being skipped; if it's still not searched
/// (it isn't in a folder searched, or in another skip), it's a folder of its own.
fn add_documents(settings: &mut Settings, path: &str) {
    settings.skipped.retain(|skip| skip != path);
    if searched_in(Path::new(path), &settings.folders, &settings.skipped).is_none() {
        push(&mut settings.folders, path);
    }
}

fn push(list: &mut Vec<String>, item: &str) {
    if !list.iter().any(|there| there == item) {
        list.push(item.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A made-up disk: these folders exist; a name ending in "repo" has a .git.
    const DISK: &[&str] = &["/", "/home", "/home/me", "/home/me/Documents", "/home/me/Documents/Trips",
                            "/home/me/Documents/Old", "/home/me/Documents/Old/Scans", "/home/me/git", "/home/me/git/repo",
                            "/home/me/Documents/repo", "/home/me/Inbox", "/usr/share/doc", "/var/tmp",
                            "/run/media/me/USB", "/mnt/data", "/tmp/sent"];

    fn settings() -> Settings {
        Settings {
            folders: vec!["/home/me/Documents".into()],
            skipped: vec!["/home/me/Documents/Old".into()],
            ..Settings::default()
        }
    }

    fn looked(path: &str, settings: &Settings) -> Look {
        look(Path::new(path), settings, Some(Path::new("/home/me")), |path| DISK.iter().any(|folder| Path::new(folder) == path),
             |path| path.file_name().is_some_and(|name| name == ".git")
                 && path.parent().is_some_and(|folder| folder.to_string_lossy().ends_with("repo")))
    }

    #[test]
    fn what_isnt_added() {
        let refused = |path: &str| looked(path, &settings()).refused.unwrap_or_default();
        assert!(refused("/").contains("whole computer"));
        assert!(refused("/home/me").contains("whole home folder"));
        assert!(refused("/home").contains("holds your home folder"));
        assert!(refused("/usr/share/doc").contains("system's folders"));
        assert!(refused("/var/tmp").contains("system's folders"));
        assert!(refused("/home/me/Nowhere").contains("no folder at"));
        for fine in ["/run/media/me/USB", "/mnt/data", "/tmp/sent", "/home/me/Inbox"] {
            assert_eq!(looked(fine, &settings()).refused, None, "{fine}");
        }
        assert_eq!(looked("/", &settings()).kind, Kind::Refused);
    }

    #[test]
    fn a_new_folder_and_its_subfolders_left_out() {
        let look = looked("/home/me/Inbox", &settings());
        assert_eq!((look.kind, look.code, look.name.as_str()), (Kind::New, false, "Inbox"));
        let mut chosen = settings();
        let choice = Choice { skipped: vec!["/home/me/Inbox/node_modules".into(), "/elsewhere".into()], ..Choice::default() };
        assert!(apply(&mut chosen, &look, &choice));
        assert_eq!(chosen.folders, ["/home/me/Documents", "/home/me/Inbox"]);
        assert_eq!(chosen.skipped, ["/home/me/Documents/Old", "/home/me/Inbox/node_modules"], "only its own subfolders");
        assert!(!apply(&mut chosen.clone(), &looked("/home/me/Inbox", &chosen), &choice), "the second time it's inside");
    }

    #[test]
    fn a_folder_searched_already_becomes_the_scope() {
        let look = looked("/home/me/Documents/Trips", &settings());
        assert_eq!((look.kind, look.within.as_deref()), (Kind::Inside, Some("/home/me/Documents")));
        assert!(look.skipped.is_empty());
        let mut same = settings();
        assert!(!apply(&mut same, &look, &Choice::default()), "nothing to index");
        assert_eq!((same.folders, same.skipped), (settings().folders, settings().skipped));
        // A chosen folder itself.
        assert_eq!(looked("/home/me/Documents", &settings()).kind, Kind::Inside);
        // Its skipped folders can be taken in.
        let look = looked("/home/me/Documents", &settings());
        assert_eq!(look.skipped, ["/home/me/Documents/Old"]);
        let mut taken = settings();
        let choice = Choice { take_in: vec!["/home/me/Documents/Old".into(), "/home/me/Inbox".into()], ..Choice::default() };
        assert!(apply(&mut taken, &look, &choice));
        assert!(taken.skipped.is_empty());
    }

    #[test]
    fn a_skipped_folder_is_taken_in_again() {
        let look = looked("/home/me/Documents/Old", &settings());
        assert_eq!(look.kind, Kind::New, "skipped: not searched");
        let mut chosen = settings();
        assert!(apply(&mut chosen, &look, &Choice::default()));
        assert_eq!((chosen.folders, chosen.skipped), (vec!["/home/me/Documents".to_string()], Vec::<String>::new()),
                   "the skip goes, and the folder it's in searches it");
        // One deeper in a skipped folder is a folder of its own.
        let look = looked("/home/me/Documents/Old/Scans", &settings());
        let mut chosen = settings();
        assert!(apply(&mut chosen, &look, &Choice::default()));
        assert_eq!(chosen.folders, ["/home/me/Documents", "/home/me/Documents/Old/Scans"]);
        assert_eq!(chosen.skipped, ["/home/me/Documents/Old"]);
    }

    #[test]
    fn a_repo_goes_into_code_search() {
        let look = looked("/home/me/git/repo", &settings());
        assert_eq!((look.kind, look.code, look.documents), (Kind::Repo, true, false));
        let mut chosen = settings();
        let choice = Choice { skipped: vec!["/home/me/git/repo/data".into()], ..Choice::default() };
        assert!(apply(&mut chosen, &look, &choice));
        assert_eq!((chosen.code_folders.as_slice(), chosen.code_skipped.as_slice()),
                   (&["/home/me/git/repo".to_string()][..], &["/home/me/git/repo/data".to_string()][..]));
        assert_eq!(chosen.folders, settings().folders, "not as documents unless asked");
        // Also as documents.
        let mut both = settings();
        assert!(apply(&mut both, &look, &Choice { documents: true, ..choice.clone() }));
        assert_eq!(both.folders, ["/home/me/Documents", "/home/me/git/repo"]);
        assert!(both.skipped.contains(&"/home/me/git/repo/data".to_string()));
        // A repo in a document folder: as documents already.
        let look = looked("/home/me/Documents/repo", &settings());
        assert_eq!((look.kind, look.documents), (Kind::Repo, true));
        let mut chosen = settings();
        assert!(apply(&mut chosen, &look, &Choice { documents: true, ..Choice::default() }));
        assert_eq!(chosen.folders, settings().folders);
        // Once it's a code folder, it and the folders in it are code search's scope.
        let mut code = settings();
        code.code_folders = vec!["/home/me/git".into()];
        let look = looked("/home/me/git/repo", &code);
        assert_eq!((look.kind, look.code, look.within.as_deref()), (Kind::Inside, true, Some("/home/me/git")));
    }
}
