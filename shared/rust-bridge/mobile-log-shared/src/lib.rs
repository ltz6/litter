use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredLogEvent {
    pub timestamp_ms: i64,
    pub level: String,
    pub source: String,
    pub platform: String,
    pub subsystem: String,
    pub category: String,
    pub message: String,
    pub session_id: Option<String>,
    pub server_id: Option<String>,
    pub thread_id: Option<String>,
    pub request_id: Option<String>,
    pub payload_json: Option<String>,
    pub fields_json: Option<String>,
    pub device_id: String,
    pub device_name: String,
    pub app_version: Option<String>,
    pub build: Option<String>,
    pub process_id: u32,
}
