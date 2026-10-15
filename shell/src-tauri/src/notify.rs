//! Desktop notifications with buttons (the freedesktop Notifications service on the session bus: GNOME Shell's, or
//! any other desktop's): "Claude Code added ~/git/app to DigUp" with Undo (tools.rs). Tauri's notification plugin has
//! no buttons on Linux, so this talks to the service itself, with the zbus the single-instance plugin brings.
//!
//! A button pressed (or the notification clicked: the "default" action) calls back once; a notification closed
//! without one forgets its callback.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, Once};
use zbus::blocking::Connection;
use zbus::zvariant::Value;

const SERVICE: &str = "org.freedesktop.Notifications";
const PATH: &str = "/org/freedesktop/Notifications";

type Callback = Box<dyn FnOnce(String) + Send>;

pub struct Notifier {
    connection: Mutex<Option<Connection>>,
    waiting: Arc<Mutex<HashMap<u32, Callback>>>,
    listening: Once,
}

impl Default for Notifier {
    fn default() -> Notifier {
        Notifier { connection: Mutex::new(None), waiting: Arc::default(), listening: Once::new() }
    }
}

impl Notifier {
    /// Shows a notification with these (key, label) buttons; `then` gets the key of the one pressed ("default" for a
    /// click on it). Its id, or why it couldn't be shown (no notification service).
    pub fn show(&self, summary: &str, body: &str, buttons: &[(&str, &str)], then: impl FnOnce(String) + Send + 'static)
                -> Result<u32, String> {
        let connection = self.connection()?;
        self.listen(&connection);
        let actions: Vec<&str> = buttons.iter().flat_map(|(key, label)| [*key, *label]).collect();
        let mut hints: HashMap<&str, Value> = HashMap::new();
        hints.insert("desktop-entry", Value::from("digup"));   // its icon and name: the installed app's
        let reply = connection
            .call_method(Some(SERVICE), PATH, Some(SERVICE), "Notify",
                         &("DigUp", 0u32, "", summary, body, actions, hints, -1i32))
            .map_err(|error| format!("no notification: {error}"))?;
        let id: u32 = reply.body().deserialize().map_err(|error| format!("no notification: {error}"))?;
        self.waiting.lock().unwrap().insert(id, Box::new(then));
        Ok(id)
    }

    fn connection(&self) -> Result<Connection, String> {
        let mut connection = self.connection.lock().unwrap();
        if connection.is_none() {
            *connection = Some(Connection::session().map_err(|error| format!("no session bus: {error}"))?);
        }
        Ok(connection.clone().unwrap())
    }

    /// Hears the service's ActionInvoked and NotificationClosed, once, on a thread of its own.
    fn listen(&self, connection: &Connection) {
        self.listening.call_once(|| {
            let connection = connection.clone();
            let waiting = self.waiting.clone();
            std::thread::spawn(move || {
                // From the service only: another program can't press its buttons.
                let rule = match zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(SERVICE)
                    .and_then(|rule| rule.interface(SERVICE)).and_then(|rule| rule.path(PATH)) {
                    Ok(rule) => rule.build(),
                    Err(error) => return log_error!("digup-shell: notifications: {error}"),
                };
                let messages = match zbus::blocking::MessageIterator::for_match_rule(rule, &connection, Some(16)) {
                    Ok(messages) => messages,
                    Err(error) => return log_error!("digup-shell: can't hear notifications' buttons: {error}"),
                };
                for message in messages.flatten() {
                    let header = message.header();
                    match header.member().map(|member| member.as_str()) {
                        Some("ActionInvoked") => {
                            if let Ok((id, key)) = message.body().deserialize::<(u32, String)>() {
                                let then = waiting.lock().unwrap().remove(&id);
                                if let Some(then) = then {
                                    then(key);
                                }
                            }
                        }
                        Some("NotificationClosed") => {
                            if let Ok((id, _)) = message.body().deserialize::<(u32, u32)>() {
                                waiting.lock().unwrap().remove(&id);
                            }
                        }
                        _ => {}
                    }
                }
            });
        });
    }
}
