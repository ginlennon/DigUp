//! The panel's folder scope: a query that starts with `in:<folder> ` searches only inside that folder (search-service's
//! `folders`). What's typed after `in:` is found among the chosen folders, in this order:
//! - a path, `/…` or `~/…`: that folder, when it's a chosen folder, inside one, or holds one;
//! - a chosen folder's name: `in:Documents`;
//! - the name of a folder right inside a chosen one: `in:Trips` for ~/Documents/Trips;
//! - a name and more: `in:Pictures/2026` is the folder 2026 in the folder found for "Pictures".
//!
//! Names match without regard to case. Two folders of the same name: the shorter path wins, and the panel shows which
//! one it took. The panel turns the found folder into a chip and searches with what follows; `code:` comes after it
//! (`in:billing code: retry`), as `code:` is always the start of what's searched.

use serde::Serialize;
use std::path::{Path, PathBuf};

/// The folder an `in:` names.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Folder {
    /// Its absolute path, for search-service.
    pub path: String,
    /// Its name, for the chip ("in Documents").
    pub name: String,
    /// Another folder has that name too: the chip shows the path, so it's clear which one is searched.
    pub ambiguous: bool,
}

/// Finds the folder `typed` names among the chosen `roots`. `home` expands `~`; `subfolders(root)` lists the names of
/// the folders right inside a root and `is_dir` says whether a path is a folder (both look at the disk; tests make
/// them up). Err is what the panel says instead.
pub fn resolve(typed: &str, roots: &[String], home: Option<&str>, subfolders: impl Fn(&Path) -> Vec<String>,
               is_dir: impl Fn(&Path) -> bool) -> Result<Folder, String> {
    let typed = typed.trim();
    let wanted = typed.trim_end_matches('/');
    if wanted.is_empty() {
        return Err("Type a folder after in:".into());
    }
    let roots: Vec<PathBuf> = roots.iter().map(|root| PathBuf::from(root.trim_end_matches('/'))).collect();
    let unknown = || Err(format!("No chosen folder called {typed}"));

    // A path: the folder itself, if DigUp searches in it at all.
    if wanted.starts_with('/') || wanted == "~" || wanted.starts_with("~/") {
        let path = match (wanted.strip_prefix('~'), home) {
            (Some(rest), Some(home)) => PathBuf::from(format!("{}{rest}", home.trim_end_matches('/'))),
            (Some(_), None) => return unknown(),
            (None, _) => PathBuf::from(wanted),
        };
        if !is_dir(&path) {
            return Err(format!("No folder at {typed}"));
        }
        if !roots.iter().any(|root| path.starts_with(root) || root.starts_with(&path)) {
            return Err(format!("{typed} isn't in a chosen folder"));
        }
        return Ok(found(vec![path]));
    }

    // A name, maybe with more after it.
    let (first, rest) = match wanted.split_once('/') {
        Some((first, rest)) => (first, Some(rest)),
        None => (wanted, None),
    };
    let same = |name: &str| name.to_lowercase() == first.to_lowercase();
    let mut candidates: Vec<PathBuf> =
        roots.iter().filter(|root| root.file_name().and_then(|name| name.to_str()).is_some_and(same)).cloned().collect();
    if candidates.is_empty() {
        for root in &roots {
            candidates.extend(subfolders(root).iter().filter(|name| same(name)).map(|name| root.join(name)));
        }
    }
    if let Some(rest) = rest {
        candidates = candidates.into_iter().map(|folder| folder.join(rest)).filter(|folder| is_dir(folder)).collect();
    }
    if candidates.is_empty() {
        return unknown();
    }
    Ok(found(candidates))
}

/// The shortest of the folders found (the first of those as short), and whether there were others.
fn found(mut candidates: Vec<PathBuf>) -> Folder {
    let ambiguous = candidates.len() > 1;
    candidates.sort_by_key(|path| path.as_os_str().len());   // stable: the first of the shortest
    let path = candidates.swap_remove(0);
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    Folder { path: path.display().to_string(), name, ambiguous }
}

/// The folders right inside `root` that a person would name: not hidden ones.
pub fn subfolders(root: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(root) else { return Vec::new() };
    entries
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| !name.starts_with('.'))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A made-up disk: these folders exist, and each one's subfolders are the ones listed under it.
    const DISK: &[&str] = &[
        "/home/me", "/home/me/Documents", "/home/me/Documents/Trips", "/home/me/Documents/Big Folder",
        "/home/me/Pictures", "/home/me/Pictures/2026", "/home/me/Pictures/Trips", "/home/me/Pictures/Trips/Rome",
        "/media/usb/Documents", "/elsewhere",
    ];

    fn resolved(typed: &str, roots: &[&str]) -> Result<Folder, String> {
        let roots: Vec<String> = roots.iter().map(|root| root.to_string()).collect();
        let subfolders = |root: &Path| {
            DISK.iter().map(Path::new).filter(|path| path.parent() == Some(root))
                .map(|path| path.file_name().unwrap().to_string_lossy().into_owned()).collect()
        };
        resolve(typed, &roots, Some("/home/me"), subfolders, |path| DISK.iter().any(|folder| Path::new(folder) == path))
    }

    fn path(typed: &str, roots: &[&str]) -> String {
        resolved(typed, roots).map(|folder| folder.path).unwrap_or_else(|error| error)
    }

    const ROOTS: &[&str] = &["/home/me/Documents", "/home/me/Pictures"];

    #[test]
    fn a_chosen_folder_by_name_or_path() {
        assert_eq!(resolved("Documents", ROOTS),
                   Ok(Folder { path: "/home/me/Documents".into(), name: "Documents".into(), ambiguous: false }));
        assert_eq!(path("documents", ROOTS), "/home/me/Documents", "case doesn't matter");
        assert_eq!(path("Pictures/", ROOTS), "/home/me/Pictures");
        assert_eq!(path("~/Pictures/2026", ROOTS), "/home/me/Pictures/2026");
        assert_eq!(path("/home/me/Documents/Trips", ROOTS), "/home/me/Documents/Trips");
        assert_eq!(path("~", ROOTS), "/home/me", "a folder that holds chosen ones");
    }

    #[test]
    fn a_folder_inside_a_chosen_one() {
        assert_eq!(path("2026", ROOTS), "/home/me/Pictures/2026");
        assert_eq!(path("big folder", ROOTS), "/home/me/Documents/Big Folder");
        assert_eq!(path("Pictures/2026", ROOTS), "/home/me/Pictures/2026");
        assert_eq!(path("Pictures/Trips/Rome", ROOTS), "/home/me/Pictures/Trips/Rome");
        // Only right inside: Rome is two levels down.
        assert_eq!(path("Rome", ROOTS), "No chosen folder called Rome");
    }

    #[test]
    fn the_same_name_twice_takes_the_shorter_path() {
        let trips = resolved("Trips", ROOTS).unwrap();
        assert_eq!((trips.path.as_str(), trips.ambiguous), ("/home/me/Pictures/Trips", true),
                   "~/Pictures/Trips is a letter shorter than ~/Documents/Trips");
        let documents = resolved("Documents", &["/media/usb/Documents", "/home/me/Documents"]).unwrap();
        assert_eq!((documents.path.as_str(), documents.ambiguous), ("/home/me/Documents", true));
        // A chosen folder's name wins over a subfolder of the same name.
        let roots = ["/home/me/Pictures", "/home/me"];
        assert_eq!(resolved("Pictures", &roots).map(|folder| folder.ambiguous), Ok(false));
    }

    #[test]
    fn what_isnt_there_or_isnt_chosen() {
        assert_eq!(path("Music", ROOTS), "No chosen folder called Music");
        assert_eq!(path("~/Music", ROOTS), "No folder at ~/Music");
        assert_eq!(path("/elsewhere", ROOTS), "/elsewhere isn't in a chosen folder");
        assert_eq!(path("Pictures/1999", ROOTS), "No chosen folder called Pictures/1999");
        assert_eq!(path("  ", ROOTS), "Type a folder after in:");
        assert_eq!(path("Documents", &[]), "No chosen folder called Documents");
    }
}
