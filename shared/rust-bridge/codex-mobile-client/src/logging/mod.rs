use std::sync::OnceLock;

use tracing::Level;

static TRACING_SUBSCRIBER_INSTALLED: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevelName {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevelName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trace => "TRACE",
            Self::Debug => "DEBUG",
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }

    fn into_tracing(self) -> Level {
        match self {
            Self::Trace => Level::TRACE,
            Self::Debug => Level::DEBUG,
            Self::Info => Level::INFO,
            Self::Warn => Level::WARN,
            Self::Error => Level::ERROR,
        }
    }
}

pub(crate) fn install_tracing_subscriber() {
    TRACING_SUBSCRIBER_INSTALLED.get_or_init(|| {
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .without_time()
            .compact()
            .with_target(true)
            .with_max_level(Level::TRACE)
            .finish();
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

pub(crate) fn log_rust(
    level: LogLevelName,
    subsystem: impl Into<String>,
    category: impl Into<String>,
    message: impl Into<String>,
    fields_json: Option<String>,
) {
    install_tracing_subscriber();

    let subsystem = subsystem.into();
    let category = category.into();
    let message = message.into();
    let fields_json = fields_json.filter(|value| !value.trim().is_empty());

    match (level.into_tracing(), fields_json.as_deref()) {
        (Level::TRACE, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::TRACE,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::DEBUG, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::DEBUG,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::INFO, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::INFO,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::WARN, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::WARN,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::ERROR, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::ERROR,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::TRACE, None) => {
            tracing::event!(target: "mobile", Level::TRACE, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::DEBUG, None) => {
            tracing::event!(target: "mobile", Level::DEBUG, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::INFO, None) => {
            tracing::event!(target: "mobile", Level::INFO, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::WARN, None) => {
            tracing::event!(target: "mobile", Level::WARN, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::ERROR, None) => {
            tracing::event!(target: "mobile", Level::ERROR, subsystem = %subsystem, category = %category, "{message}");
        }
    }
}

pub(crate) fn install_ipc_wire_trace_logger() {
    install_tracing_subscriber();
}

#[cfg(test)]
mod tests {
    use super::LogLevelName;

    #[test]
    fn log_level_name_strings_match_expected_format() {
        assert_eq!(LogLevelName::Trace.as_str(), "TRACE");
        assert_eq!(LogLevelName::Debug.as_str(), "DEBUG");
        assert_eq!(LogLevelName::Info.as_str(), "INFO");
        assert_eq!(LogLevelName::Warn.as_str(), "WARN");
        assert_eq!(LogLevelName::Error.as_str(), "ERROR");
    }
}
