//! The search panel's size and place. With nothing searched it's its grip strip and two fields high; with results
//! it's the height the person gave it (480 until they resize it), and as wide as they made it. Undecorated, it has no
//! frame of its own: it's dragged by the grip strip at its top, its icons, the room around its fields and its footer
//! (panel.js), and resized by its edges —
//! Tauri gives an undecorated, resizable window a 5 px border all round (on Linux a handler on the web view) that
//! starts the desktop's resize, with the resize cursors, and keeps the press from the page. What the person sets is saved in the
//! settings (`panelWidth`, `panelHeight`).
//!
//! Where it goes is the desktop's business on Wayland: an app can't place its own window there (GTK ignores the
//! position asked for). GNOME keeps a place it was dragged to while it's open; once hidden it's a new window to GNOME
//! when it opens again, placed as GNOME places new windows. On X11 it opens where the person last dragged it
//! (`panelPosition`), else centered a fifth of the way down the screen with the pointer.
//!
//! The window takes sizes for three reasons: the shell asking (results come and go), the person resizing it, and the
//! desktop. Only the person's are saved, so a size counts as theirs only after a press on its edge (`grab`; main.rs
//! hears of it from GTK, before Tauri's handler) — a late configure from a resize the shell asked for, arriving after the results came, would
//! otherwise be saved as the person's height. Where the shell can't hear of the press (not Linux), a size counts as
//! theirs once the shell's own request has settled.

use std::time::{Duration, Instant};

/// The panel's height with nothing searched: the grip strip (10), the field (52) and the keyword filter under it (32),
/// as panel.css has them.
pub const FIELD_HEIGHT: f64 = 94.0;
pub const DEFAULT_WIDTH: f64 = 780.0;
/// The height with results.
pub const DEFAULT_HEIGHT: f64 = 480.0;
/// The narrowest: the list and some of the preview beside it.
pub const MIN_WIDTH: f64 = 520.0;
/// The lowest with results: the fields, a few rows and the footer (lower, there'd be no room for results at all).
pub const MIN_RESULTS_HEIGHT: f64 = 240.0;
/// Larger than any screen: a hand-edited settings file can't make it absurd.
pub const MAX_SIDE: f64 = 8000.0;
/// A focus loss this soon after a drag or resize starts is the desktop's grab, not a click elsewhere: GNOME takes
/// the keyboard away while it moves or resizes a window and gives it back after.
const GRAB_GRACE: Duration = Duration::from_millis(1500);
/// Without word of edge presses: a size this long after the shell's own request is someone else's.
const SETTLED: Duration = Duration::from_millis(600);
/// Tauri's resize border, in logical pixels (tauri-runtime-wry's undecorated_resizing.rs): a press this close to an
/// edge resizes the window.
pub const EDGE: f64 = 5.0;

/// A saved width, kept within reason (none or nonsense: the default).
pub fn width(saved: f64) -> f64 {
    if saved.is_finite() && saved > 0.0 { saved.clamp(MIN_WIDTH, MAX_SIDE) } else { DEFAULT_WIDTH }
}

/// A saved height with results, the same way.
pub fn results_height(saved: f64) -> f64 {
    if saved.is_finite() && saved > 0.0 { saved.clamp(MIN_RESULTS_HEIGHT, MAX_SIDE) } else { DEFAULT_HEIGHT }
}

/// A size to show, fitted to the screen it's on (logical pixels; none known: as it is). Never below the minimums,
/// which a tiny screen can't take away.
pub fn fitted((width, height): (f64, f64), screen: Option<(f64, f64)>) -> (f64, f64) {
    match screen {
        Some((screen_width, screen_height)) => {
            (width.min(screen_width).max(MIN_WIDTH), height.min(screen_height * 0.9).max(FIELD_HEIGHT))
        }
        None => (width, height),
    }
}

/// The desktop is a Wayland one and GTK speaks Wayland to it (not X11 through XWayland, as with GDK_BACKEND=x11):
/// the panel can't place itself.
pub fn is_wayland(wayland_display: Option<&str>, gdk_backend: Option<&str>) -> bool {
    let first = gdk_backend.and_then(|backends| backends.split(',').map(str::trim).find(|backend| !backend.is_empty()));
    wayland_display.is_some_and(|display| !display.is_empty()) && !matches!(first, Some(backend) if backend != "wayland" && backend != "*")
}

/// A press here resizes the window `(left, top, right, bottom)`: it's on Tauri's border, as Tauri's own hit test
/// reads it.
pub fn on_edge((left, top, right, bottom): (f64, f64, f64, f64), x: f64, y: f64, border: f64) -> bool {
    x < left + border || x >= right - border || y < top + border || y >= bottom - border
}

/// What the person is doing to the window, from the edge or icon they pressed until the panel hides.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Grab {
    Move,
    Resize,
}

#[derive(Debug)]
pub struct Panel {
    /// The person's width, and height with results.
    pub width: f64,
    pub height: f64,
    /// Results are showing (else it's the fields only).
    pub results: bool,
    /// X11: where the person dragged it (physical pixels); none: centered.
    pub position: Option<[i32; 2]>,
    grab: Option<(Grab, Instant)>,
    /// The shell hears of presses on the edges (Linux: from GTK), so only sizes after one are the person's.
    edges_heard: bool,
    /// When the shell last asked for a size.
    asked: Option<Instant>,
}

/// How the window may be resized now: the minimum size, and the maximum height (the fields only: none).
#[derive(Debug, PartialEq)]
pub struct Limits {
    pub min: (f64, f64),
    pub max_height: Option<f64>,
}

impl Panel {
    pub fn new(width: f64, height: f64, position: Option<[i32; 2]>, edges_heard: bool) -> Panel {
        Panel { width: self::width(width), height: results_height(height), results: false, position, grab: None,
                edges_heard, asked: None }
    }

    /// The size the window should have now.
    pub fn size(&self) -> (f64, f64) {
        (self.width, if self.results { self.height } else { FIELD_HEIGHT })
    }

    /// With nothing searched only the width can change: the fields don't get taller.
    pub fn limits(&self) -> Limits {
        match self.results {
            true => Limits { min: (MIN_WIDTH, MIN_RESULTS_HEIGHT), max_height: None },
            false => Limits { min: (MIN_WIDTH, FIELD_HEIGHT), max_height: Some(FIELD_HEIGHT) },
        }
    }

    /// Results came or went; true: the window changes size. A resize by the edge ends with it (the sizes that follow
    /// are the shell's).
    pub fn show_results(&mut self, shown: bool) -> bool {
        let changed = self.results != shown;
        self.results = shown;
        if changed && matches!(self.grab, Some((Grab::Resize, _))) {
            self.grab = None;
        }
        changed
    }

    /// The person pressed an edge, or started dragging.
    pub fn grab(&mut self, grab: Grab, now: Instant) {
        self.grab = Some((grab, now));
    }

    /// The panel hid: what the person was doing to it is over.
    pub fn hidden(&mut self) {
        self.grab = None;
    }

    /// A focus loss the panel shouldn't hide for: it came as a drag or resize began.
    pub fn keeps_through_focus_loss(&self, now: Instant) -> bool {
        self.grab.is_some_and(|(_, started)| now.saturating_duration_since(started) < GRAB_GRACE)
    }

    /// The shell asks the window for the size it should have (`size`).
    pub fn asking(&mut self, now: Instant) {
        self.asked = Some(now);
    }

    /// The window took this size (logical pixels); true: it's the person's new size, to be saved.
    pub fn resized(&mut self, width: f64, height: f64, now: Instant) -> bool {
        let theirs = match self.edges_heard {
            true => matches!(self.grab, Some((Grab::Resize, _))),
            false => self.asked.is_none_or(|asked| now.saturating_duration_since(asked) >= SETTLED),
        };
        if !theirs || width < 1.0 || height < 1.0 {
            return false;
        }
        let (new_width, new_height) = (self::width(width), if self.results { results_height(height) } else { self.height });
        if (new_width - self.width).abs() < 1.0 && (new_height - self.height).abs() < 1.0 {
            return false;
        }
        (self.width, self.height) = (new_width, new_height);
        true
    }

    /// X11: the window is here now (physical pixels); true: the person put it there, to be saved.
    pub fn moved(&mut self, x: i32, y: i32) -> bool {
        if self.grab.is_none() || self.position == Some([x, y]) {
            return false;
        }
        self.position = Some([x, y]);
        true
    }

    /// Settings' Reset Size: the default size, centered again.
    pub fn reset(&mut self) {
        (self.width, self.height, self.position) = (DEFAULT_WIDTH, DEFAULT_HEIGHT, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_sizes_are_kept_within_reason() {
        assert_eq!((width(900.0), results_height(700.0)), (900.0, 700.0));
        assert_eq!((width(100.0), results_height(90.0)), (MIN_WIDTH, MIN_RESULTS_HEIGHT));
        assert_eq!((width(1e9), results_height(1e9)), (MAX_SIDE, MAX_SIDE));
        assert_eq!((width(f64::NAN), results_height(0.0)), (DEFAULT_WIDTH, DEFAULT_HEIGHT), "nonsense: the defaults");
    }

    #[test]
    fn the_fields_height_is_panel_css() {
        let css = include_str!("../../ui/panel.css");
        let height = |rule: &str| -> f64 {
            let block = css.split(&format!("\n{rule} {{\n")).nth(1).and_then(|rest| rest.split('}').next())
                .unwrap_or_else(|| panic!("no {rule} in panel.css"));
            let line = block.lines().find_map(|line| line.trim().strip_prefix("height: "))
                .unwrap_or_else(|| panic!("{rule} has no height"));
            line.trim_end_matches(';').trim_end_matches("px").parse().unwrap()
        };
        assert_eq!(height(".grip") + height(".field") + height(".filter-field"), FIELD_HEIGHT);
    }

    #[test]
    fn fitted_to_the_screen() {
        assert_eq!(fitted((780.0, 480.0), Some((1920.0, 1080.0))), (780.0, 480.0));
        assert_eq!(fitted((2400.0, 1400.0), Some((1280.0, 800.0))), (1280.0, 720.0));
        assert_eq!(fitted((780.0, FIELD_HEIGHT), Some((400.0, 60.0))), (MIN_WIDTH, FIELD_HEIGHT), "never below the minimums");
        assert_eq!(fitted((780.0, 480.0), None), (780.0, 480.0));
    }

    #[test]
    fn grows_with_results_to_the_persons_height() {
        let mut panel = Panel::new(900.0, 600.0, None, true);
        assert_eq!(panel.size(), (900.0, FIELD_HEIGHT));
        assert_eq!(panel.limits(), Limits { min: (MIN_WIDTH, FIELD_HEIGHT), max_height: Some(FIELD_HEIGHT) });
        assert!(panel.show_results(true) && !panel.show_results(true), "once");
        assert_eq!(panel.size(), (900.0, 600.0));
        assert_eq!(panel.limits(), Limits { min: (MIN_WIDTH, MIN_RESULTS_HEIGHT), max_height: None });
        assert!(panel.show_results(false));
        assert_eq!(panel.size(), (900.0, FIELD_HEIGHT));
    }

    #[test]
    fn only_sizes_after_an_edge_press_are_the_persons() {
        let now = Instant::now();
        let mut panel = Panel::new(DEFAULT_WIDTH, DEFAULT_HEIGHT, None, true);
        panel.show_results(true);
        // A late configure from the fields-only size, after the results came: not saved.
        assert!(!panel.resized(DEFAULT_WIDTH, FIELD_HEIGHT, now));
        assert_eq!(panel.size(), (DEFAULT_WIDTH, DEFAULT_HEIGHT));
        // Moving isn't resizing either.
        panel.grab(Grab::Move, now);
        assert!(!panel.resized(1000.0, 700.0, now));
        panel.grab(Grab::Resize, now);
        assert!(!panel.resized(DEFAULT_WIDTH, DEFAULT_HEIGHT, now), "the same size: nothing to save");
        assert!(panel.resized(1000.0, 700.0, now));
        assert_eq!(panel.size(), (1000.0, 700.0));
        assert!(panel.resized(300.0, 100.0, now), "kept within the minimums");
        assert_eq!(panel.size(), (MIN_WIDTH, MIN_RESULTS_HEIGHT));
        // The results go: the edge's resize is over, and the fields' height isn't the person's.
        panel.show_results(false);
        assert!(!panel.resized(MIN_WIDTH, FIELD_HEIGHT, now));
        assert_eq!(panel.height, MIN_RESULTS_HEIGHT);
    }

    #[test]
    fn with_nothing_searched_the_edges_change_the_width_only() {
        let now = Instant::now();
        let mut panel = Panel::new(DEFAULT_WIDTH, 600.0, None, true);
        panel.grab(Grab::Resize, Instant::now());
        assert!(panel.resized(640.0, FIELD_HEIGHT, now));
        assert_eq!((panel.width, panel.height), (640.0, 600.0));
        panel.hidden();
        assert!(!panel.resized(900.0, FIELD_HEIGHT, now), "hidden: the grab is over");
    }

    #[test]
    fn a_focus_loss_as_a_drag_begins_is_kept_through() {
        let now = Instant::now();
        let mut panel = Panel::new(DEFAULT_WIDTH, DEFAULT_HEIGHT, None, true);
        assert!(!panel.keeps_through_focus_loss(now), "no drag: it hides");
        panel.grab(Grab::Move, now);
        assert!(panel.keeps_through_focus_loss(now + Duration::from_millis(200)));
        assert!(!panel.keeps_through_focus_loss(now + Duration::from_secs(5)), "later it's a click elsewhere");
        panel.grab(Grab::Resize, now);
        panel.hidden();
        assert!(!panel.keeps_through_focus_loss(now));
    }

    #[test]
    fn a_place_is_the_persons_only_while_they_drag() {
        let mut panel = Panel::new(DEFAULT_WIDTH, DEFAULT_HEIGHT, None, true);
        assert!(!panel.moved(560, 216), "where the shell put it");
        panel.grab(Grab::Move, Instant::now());
        assert!(panel.moved(100, 50) && !panel.moved(100, 50));
        assert_eq!(panel.position, Some([100, 50]));
        panel.reset();
        assert_eq!((panel.size(), panel.position), ((DEFAULT_WIDTH, FIELD_HEIGHT), None));
    }

    #[test]
    fn without_word_of_edge_presses_a_size_counts_once_the_shells_has_settled() {
        let now = Instant::now();
        let mut panel = Panel::new(DEFAULT_WIDTH, DEFAULT_HEIGHT, None, false);
        panel.show_results(true);
        panel.asking(now);
        assert!(!panel.resized(DEFAULT_WIDTH, FIELD_HEIGHT, now + Duration::from_millis(100)), "a late configure");
        assert!(panel.resized(1000.0, 700.0, now + Duration::from_secs(2)));
        assert_eq!(panel.size(), (1000.0, 700.0));
    }

    #[test]
    fn edges_as_tauri_reads_them() {
        // As measured in the panel 900 wide: a press at x 895 resized it, at 894 the page had it.
        let window = (0.0, 0.0, 900.0, 560.0);
        for (x, y) in [(0.0, 300.0), (4.9, 300.0), (895.0, 280.0), (899.0, 280.0), (450.0, 0.0), (450.0, 555.0)] {
            assert!(on_edge(window, x, y, EDGE), "{x},{y} is on the edge");
        }
        for (x, y) in [(5.0, 300.0), (894.0, 280.0), (450.0, 5.0), (450.0, 554.5), (30.0, 28.0)] {
            assert!(!on_edge(window, x, y, EDGE), "{x},{y} is inside");
        }
        assert!(on_edge(window, 9.0, 300.0, 2.0 * EDGE), "the border grows with the screen's scale");
    }

    #[test]
    fn wayland_or_not() {
        assert!(is_wayland(Some("wayland-0"), None));
        assert!(is_wayland(Some("wayland-0"), Some("wayland,x11")));
        assert!(is_wayland(Some("wayland-0"), Some("*")));
        assert!(!is_wayland(Some("wayland-0"), Some("x11")), "XWayland: X11's rules");
        assert!(!is_wayland(Some("wayland-0"), Some("x11,wayland")));
        assert!(!is_wayland(None, None) && !is_wayland(Some(""), None));
    }
}
