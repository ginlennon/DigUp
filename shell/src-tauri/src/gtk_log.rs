//! GTK's own warnings, as they reach the shell's stderr log (Linux). A custom GTK theme the person installed can have
//! CSS this GTK doesn't understand, and GTK then warns "Theme parsing error: gtk.css:12:3: …" for every bad rule at
//! every start: lines that drown out the shell's own, about nothing DigUp did or can fix. Those are dropped; every
//! other message goes to GLib's default writer, as before.
//!
//! GTK 3 logs structured (G_LOG_USE_STRUCTURED), so a `g_log_set_handler` for the "Gtk" domain never sees them: the
//! process-wide writer does. GLib allows one writer per process, set before anything logs: first thing in `main`.

use glib::{LogField, LogLevel, LogWriterOutput};

/// Sends GLib's messages through `writer`.
pub fn quiet_theme_warnings() {
    glib::log_set_writer_func(writer);
}

fn writer(level: LogLevel, fields: &[LogField<'_>]) -> LogWriterOutput {
    let field = |key: &str| fields.iter().find(|field| field.key() == key).and_then(LogField::value_str);
    if is_theme_noise(level, field("GLIB_DOMAIN"), field("MESSAGE")) {
        return LogWriterOutput::Handled;
    }
    glib::log_writer_default(level, fields)
}

/// A GTK theme's CSS warning: GTK's domain, a warning, about theme parsing.
fn is_theme_noise(level: LogLevel, domain: Option<&str>, message: Option<&str>) -> bool {
    level == LogLevel::Warning && domain == Some("Gtk")
        && message.is_some_and(|message| message.starts_with("Theme parsing error"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_themes_css_warnings_are_dropped() {
        let theme = Some("Theme parsing error: gtk.css:1544:22: 'font-feature-settings' is not a valid property name");
        assert!(is_theme_noise(LogLevel::Warning, Some("Gtk"), theme));
        assert!(!is_theme_noise(LogLevel::Critical, Some("Gtk"), theme), "worse than a warning stays");
        assert!(!is_theme_noise(LogLevel::Warning, Some("GLib-GObject"), theme));
        assert!(!is_theme_noise(LogLevel::Warning, Some("Gtk"), Some("Failed to load module \"canberra-gtk-module\"")));
        assert!(!is_theme_noise(LogLevel::Warning, None, None));
    }
}
