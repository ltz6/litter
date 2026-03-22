//! Notification routing and event-driven state mutations.
//!
//! Processes upstream typed `ServerNotification` and `ServerRequest` enums
//! from `codex-app-server-protocol` and maps them to high-level `UiEvent`s
//! for platform (iOS/Android) consumption.

use std::sync::{Arc, Mutex};

use codex_app_server_protocol::{ServerNotification, ServerRequest};
use tokio::sync::broadcast;
use tracing::warn;

use crate::types::{ApprovalKind, PendingApproval, ThreadKey, generated};

/// High-level events for platform UI consumption.
///
/// Each variant represents a meaningful state change that the Swift/Kotlin
/// UI layer should react to. These are emitted by the [`EventProcessor`]
/// after processing typed upstream notifications from the server.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum UiEvent {
    // ── Thread/Turn lifecycle ──────────────────────────────────────────
    TurnStarted {
        key: ThreadKey,
        turn_id: String,
    },
    TurnCompleted {
        key: ThreadKey,
        turn_id: String,
    },
    ItemStarted {
        key: ThreadKey,
        notification: generated::ItemStartedNotification,
    },
    ItemCompleted {
        key: ThreadKey,
        notification: generated::ItemCompletedNotification,
    },

    // ── Streaming deltas ───────────────────────────────────────────────
    MessageDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    ReasoningDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    PlanDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },
    CommandOutputDelta {
        key: ThreadKey,
        item_id: String,
        delta: String,
    },

    // ── Approvals ──────────────────────────────────────────────────────
    ApprovalRequested {
        key: ThreadKey,
        approval: PendingApproval,
    },

    // ── Realtime voice ─────────────────────────────────────────────────
    RealtimeStarted {
        key: ThreadKey,
        notification: generated::ThreadRealtimeStartedNotification,
    },
    RealtimeItemAdded {
        key: ThreadKey,
        notification: generated::ThreadRealtimeItemAddedNotification,
    },
    RealtimeOutputAudioDelta {
        key: ThreadKey,
        notification: generated::ThreadRealtimeOutputAudioDeltaNotification,
    },
    RealtimeError {
        key: ThreadKey,
        notification: generated::ThreadRealtimeErrorNotification,
    },
    RealtimeClosed {
        key: ThreadKey,
        notification: generated::ThreadRealtimeClosedNotification,
    },

    // ── Account ────────────────────────────────────────────────────────
    AccountLoginCompleted {
        notification: generated::AccountLoginCompletedNotification,
    },
    AccountUpdated {
        notification: generated::AccountUpdatedNotification,
    },
    AccountRateLimitsUpdated {
        notification: generated::AccountRateLimitsUpdatedNotification,
    },

    // ── Errors ─────────────────────────────────────────────────────────
    Error {
        key: Option<ThreadKey>,
        message: String,
        code: Option<i64>,
    },

    // ── Connection ─────────────────────────────────────────────────────
    ConnectionStateChanged {
        server_id: String,
        health: String,
    },

    // ── Context ────────────────────────────────────────────────────────
    ContextTokensUpdated {
        key: ThreadKey,
        used: u64,
        limit: u64,
    },

    // ── Raw notification passthrough ─────────────────────────────────
    /// Notifications not yet handled by the EventProcessor are forwarded
    /// as raw JSON so the platform layer can still process them.
    /// `params_json` is the JSON-serialized params object.
    RawNotification {
        server_id: String,
        method: String,
        params_json: String,
    },
}

/// Processes upstream typed server notifications/requests and emits high-level [`UiEvent`]s.
///
/// The processor is `Send + Sync` — all mutable state is behind `Arc<Mutex<_>>`.
pub struct EventProcessor {
    ui_event_tx: broadcast::Sender<UiEvent>,
    pending_approvals: Arc<Mutex<Vec<PendingApproval>>>,
}

impl EventProcessor {
    /// Create a new `EventProcessor` with a default channel capacity of 256.
    pub fn new() -> Self {
        let (ui_event_tx, _) = broadcast::channel(256);
        Self {
            ui_event_tx,
            pending_approvals: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Subscribe to the stream of [`UiEvent`]s.
    pub fn subscribe(&self) -> broadcast::Receiver<UiEvent> {
        self.ui_event_tx.subscribe()
    }

    /// Return a snapshot of all pending approvals.
    pub fn pending_approvals(&self) -> Vec<PendingApproval> {
        self.pending_approvals.lock().unwrap().clone()
    }

    /// Remove and return a pending approval by its JSON-RPC request ID.
    ///
    /// Returns `None` if no approval with that ID exists.
    pub fn resolve_approval(&self, request_id: &str) -> Option<PendingApproval> {
        let mut approvals = self.pending_approvals.lock().unwrap();
        if let Some(pos) = approvals.iter().position(|a| a.id == request_id) {
            Some(approvals.remove(pos))
        } else {
            None
        }
    }

    // ── Notification processing ────────────────────────────────────────

    /// Process a typed upstream `ServerNotification`.
    ///
    /// Matches on the upstream enum variants (which carry typed payloads),
    /// extracts relevant fields directly, and emits the corresponding
    /// [`UiEvent`] to all subscribers.
    pub fn process_notification(&self, server_id: &str, notification: &ServerNotification) {
        match notification {
            // ── Turn lifecycle ──────────────────────────────────────
            ServerNotification::TurnStarted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::TurnStarted {
                    key,
                    turn_id: n.turn.id.clone(),
                });
            }
            ServerNotification::TurnCompleted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::TurnCompleted {
                    key,
                    turn_id: n.turn.id.clone(),
                });
            }

            // ── Item lifecycle ──────────────────────────────────────
            ServerNotification::ItemStarted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ItemStarted {
                    key,
                    notification: generated::ItemStartedNotification {
                        item: crate::ffi::generated_rpc::convert_generated_field(n.item.clone())
                            .expect("serialize ItemStartedNotification item"),
                        thread_id: n.thread_id.clone(),
                        turn_id: n.turn_id.clone(),
                    },
                });
            }
            ServerNotification::ItemCompleted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ItemCompleted {
                    key,
                    notification: generated::ItemCompletedNotification {
                        item: crate::ffi::generated_rpc::convert_generated_field(n.item.clone())
                            .expect("serialize ItemCompletedNotification item"),
                        thread_id: n.thread_id.clone(),
                        turn_id: n.turn_id.clone(),
                    },
                });
            }

            // ── Streaming deltas ────────────────────────────────────
            ServerNotification::AgentMessageDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::MessageDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::ReasoningTextDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ReasoningDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::ReasoningSummaryTextDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::ReasoningDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::PlanDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::PlanDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::CommandExecutionOutputDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::CommandOutputDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }
            ServerNotification::FileChangeOutputDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::CommandOutputDelta {
                    key,
                    item_id: n.item_id.clone(),
                    delta: n.delta.clone(),
                });
            }

            // ── Realtime / voice ────────────────────────────────────
            ServerNotification::ThreadRealtimeStarted(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeStarted {
                    key,
                    notification: generated::ThreadRealtimeStartedNotification {
                        thread_id: n.thread_id.clone(),
                        session_id: n.session_id.clone(),
                    },
                });
            }
            ServerNotification::ThreadRealtimeItemAdded(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeItemAdded {
                    key,
                    notification: generated::ThreadRealtimeItemAddedNotification {
                        thread_id: n.thread_id.clone(),
                        item: crate::ffi::generated_rpc::convert_generated_field(n.item.clone())
                            .unwrap_or(generated::JsonValue {
                                kind: generated::JsonValueKind::Null,
                                bool_value: None,
                                i64_value: None,
                                u64_value: None,
                                f64_value: None,
                                string_value: None,
                                array_items: None,
                                object_entries: None,
                            }),
                    },
                });
            }
            ServerNotification::ThreadRealtimeOutputAudioDelta(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeOutputAudioDelta {
                    key,
                    notification: generated::ThreadRealtimeOutputAudioDeltaNotification {
                        thread_id: n.thread_id.clone(),
                        audio: generated::ThreadRealtimeAudioChunk {
                            data: n.audio.data.clone(),
                            sample_rate: n.audio.sample_rate,
                            num_channels: n.audio.num_channels as u32,
                            samples_per_channel: n.audio.samples_per_channel,
                        },
                    },
                });
            }

            // ── Errors ──────────────────────────────────────────────
            ServerNotification::Error(n) => {
                let key = Some(Self::make_key(server_id, &n.thread_id));
                self.emit(UiEvent::Error {
                    key,
                    message: n.error.message.clone(),
                    code: n.error.codex_error_info.as_ref().map(|_| {
                        // CodexErrorInfo doesn't expose a numeric code directly;
                        // no numeric code from the typed error.
                        0i64
                    }),
                });
            }
            ServerNotification::ThreadRealtimeError(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeError {
                    key,
                    notification: generated::ThreadRealtimeErrorNotification {
                        thread_id: n.thread_id.clone(),
                        message: n.message.clone(),
                    },
                });
            }
            ServerNotification::ThreadRealtimeClosed(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                self.emit(UiEvent::RealtimeClosed {
                    key,
                    notification: generated::ThreadRealtimeClosedNotification {
                        thread_id: n.thread_id.clone(),
                        reason: n.reason.clone(),
                    },
                });
            }

            // ── Context tokens ──────────────────────────────────────
            ServerNotification::ThreadTokenUsageUpdated(n) => {
                let key = Self::make_key(server_id, &n.thread_id);
                let total = &n.token_usage.total;
                let used = (total.input_tokens + total.output_tokens) as u64;
                let limit = n.token_usage.model_context_window.unwrap_or(0) as u64;
                self.emit(UiEvent::ContextTokensUpdated { key, used, limit });
            }
            ServerNotification::AccountLoginCompleted(n) => {
                self.emit(UiEvent::AccountLoginCompleted {
                    notification: generated::AccountLoginCompletedNotification {
                        login_id: n.login_id.clone(),
                        success: n.success,
                        error: n.error.clone(),
                    },
                });
            }
            ServerNotification::AccountUpdated(n) => {
                self.emit(UiEvent::AccountUpdated {
                    notification: generated::AccountUpdatedNotification {
                        auth_mode: n.auth_mode.as_ref().map(|mode| match mode {
                            codex_app_server_protocol::AuthMode::ApiKey => {
                                generated::AuthMode::ApiKey
                            }
                            codex_app_server_protocol::AuthMode::Chatgpt => {
                                generated::AuthMode::Chatgpt
                            }
                            codex_app_server_protocol::AuthMode::ChatgptAuthTokens => {
                                generated::AuthMode::ChatgptAuthTokens
                            }
                        }),
                        plan_type: n.plan_type.map(|plan| match plan {
                            codex_protocol::account::PlanType::Free => generated::PlanType::Free,
                            codex_protocol::account::PlanType::Go => generated::PlanType::Go,
                            codex_protocol::account::PlanType::Plus => generated::PlanType::Plus,
                            codex_protocol::account::PlanType::Pro => generated::PlanType::Pro,
                            codex_protocol::account::PlanType::Team => generated::PlanType::Team,
                            codex_protocol::account::PlanType::Business => {
                                generated::PlanType::Business
                            }
                            codex_protocol::account::PlanType::Enterprise => {
                                generated::PlanType::Enterprise
                            }
                            codex_protocol::account::PlanType::Edu => generated::PlanType::Edu,
                            codex_protocol::account::PlanType::Unknown => {
                                generated::PlanType::Unknown
                            }
                        }),
                    },
                });
            }
            ServerNotification::AccountRateLimitsUpdated(n) => {
                self.emit(UiEvent::AccountRateLimitsUpdated {
                    notification: generated::AccountRateLimitsUpdatedNotification {
                        rate_limits: generated::RateLimitSnapshot {
                            limit_id: n.rate_limits.limit_id.clone(),
                            limit_name: n.rate_limits.limit_name.clone(),
                            primary: n.rate_limits.primary.as_ref().map(|window| {
                                generated::RateLimitWindow {
                                    used_percent: window.used_percent,
                                    window_duration_mins: window.window_duration_mins,
                                    resets_at: window.resets_at,
                                }
                            }),
                            secondary: n.rate_limits.secondary.as_ref().map(|window| {
                                generated::RateLimitWindow {
                                    used_percent: window.used_percent,
                                    window_duration_mins: window.window_duration_mins,
                                    resets_at: window.resets_at,
                                }
                            }),
                            credits: n.rate_limits.credits.as_ref().map(|credits| {
                                generated::CreditsSnapshot {
                                    has_credits: credits.has_credits,
                                    unlimited: credits.unlimited,
                                    balance: credits.balance.clone(),
                                }
                            }),
                            plan_type: n.rate_limits.plan_type.map(|plan| match plan {
                                codex_protocol::account::PlanType::Free => {
                                    generated::PlanType::Free
                                }
                                codex_protocol::account::PlanType::Go => generated::PlanType::Go,
                                codex_protocol::account::PlanType::Plus => {
                                    generated::PlanType::Plus
                                }
                                codex_protocol::account::PlanType::Pro => generated::PlanType::Pro,
                                codex_protocol::account::PlanType::Team => {
                                    generated::PlanType::Team
                                }
                                codex_protocol::account::PlanType::Business => {
                                    generated::PlanType::Business
                                }
                                codex_protocol::account::PlanType::Enterprise => {
                                    generated::PlanType::Enterprise
                                }
                                codex_protocol::account::PlanType::Edu => generated::PlanType::Edu,
                                codex_protocol::account::PlanType::Unknown => {
                                    generated::PlanType::Unknown
                                }
                            }),
                        },
                    },
                });
            }

            // ── Everything else: forward as raw JSON ──────────────────
            other => {
                let method = format!("{other}");
                let params_json =
                    serde_json::to_string(&other).unwrap_or_else(|_| "{}".to_string());
                self.emit(UiEvent::RawNotification {
                    server_id: server_id.to_string(),
                    method,
                    params_json,
                });
            }
        }
    }

    // ── Server request processing ──────────────────────────────────────

    /// Process a typed upstream `ServerRequest` that requires user action.
    ///
    /// Creates a [`PendingApproval`], stores it, and emits
    /// [`UiEvent::ApprovalRequested`] so the platform UI can present it.
    ///
    /// `ToolRequestUserInput` is forwarded as a raw event because it is not an
    /// approval and the mobile UI already knows how to present the full
    /// upstream question/options payload.
    pub fn process_server_request(&self, server_id: &str, request: &ServerRequest) {
        let (kind, thread_id, turn_id, item_id, command, path, cwd, reason, request_id, raw_params) =
            match request {
                ServerRequest::CommandExecutionRequestApproval { request_id, params } => {
                    let raw = serde_json::to_value(params).unwrap_or_default();
                    (
                        ApprovalKind::Command,
                        Some(params.thread_id.clone()),
                        Some(params.turn_id.clone()),
                        Some(params.item_id.clone()),
                        params.command.clone(),
                        None,
                        params.cwd.as_ref().map(|p| p.display().to_string()),
                        params.reason.clone(),
                        request_id,
                        raw,
                    )
                }
                ServerRequest::FileChangeRequestApproval { request_id, params } => {
                    let raw = serde_json::to_value(params).unwrap_or_default();
                    (
                        ApprovalKind::FileChange,
                        Some(params.thread_id.clone()),
                        Some(params.turn_id.clone()),
                        Some(params.item_id.clone()),
                        None,
                        params.grant_root.as_ref().map(|p| p.display().to_string()),
                        None,
                        params.reason.clone(),
                        request_id,
                        raw,
                    )
                }
                ServerRequest::PermissionsRequestApproval { request_id, params } => {
                    let raw = serde_json::to_value(params).unwrap_or_default();
                    (
                        ApprovalKind::Permissions,
                        Some(params.thread_id.clone()),
                        Some(params.turn_id.clone()),
                        Some(params.item_id.clone()),
                        None,
                        None,
                        None,
                        params.reason.clone(),
                        request_id,
                        raw,
                    )
                }
                ServerRequest::McpServerElicitationRequest { request_id, params } => {
                    let raw = serde_json::to_value(params).unwrap_or_default();
                    (
                        ApprovalKind::McpElicitation,
                        Some(params.thread_id.clone()),
                        params.turn_id.clone(),
                        None,
                        None,
                        None,
                        None,
                        None,
                        request_id,
                        raw,
                    )
                }
                ServerRequest::ToolRequestUserInput { request_id, params } => {
                    let _ = request_id;
                    let params_json =
                        serde_json::to_string(params).unwrap_or_else(|_| "{}".to_string());
                    self.emit(UiEvent::RawNotification {
                        server_id: server_id.to_string(),
                        method: "item/tool/requestUserInput".to_string(),
                        params_json,
                    });
                    return;
                }
                other => {
                    warn!(
                        method = ?other,
                        "unknown/unhandled server request type — ignoring"
                    );
                    return;
                }
            };

        let id = serde_json::to_value(request_id)
            .map(|v| match v {
                serde_json::Value::String(s) => s,
                other => other.to_string(),
            })
            .unwrap_or_default();
        let raw_params_json =
            serde_json::to_string(&raw_params).unwrap_or_else(|_| "{}".to_string());

        let approval = PendingApproval {
            id,
            kind,
            thread_id: thread_id.clone(),
            turn_id,
            item_id,
            command,
            path,
            cwd,
            reason,
            raw_params_json,
        };

        // Store the approval.
        self.pending_approvals
            .lock()
            .unwrap()
            .push(approval.clone());

        // Build the thread key (best-effort).
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.unwrap_or_default(),
        };

        self.emit(UiEvent::ApprovalRequested { key, approval });
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    fn emit(&self, event: UiEvent) {
        // Ignore the error — it just means there are no active subscribers.
        let _ = self.ui_event_tx.send(event);
    }

    fn make_key(server_id: &str, thread_id: &str) -> ThreadKey {
        ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        }
    }
}

impl Default for EventProcessor {
    fn default() -> Self {
        Self::new()
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::{self as proto};
    use serde_json::json;

    /// Helper: create processor, subscribe, process notification, return received event.
    fn process_and_recv(server_id: &str, notification: &ServerNotification) -> Option<UiEvent> {
        let proc = EventProcessor::new();
        let mut rx = proc.subscribe();
        proc.process_notification(server_id, notification);
        rx.try_recv().ok()
    }

    /// Helper: create processor, subscribe, process server request, return received event.
    fn request_and_recv(server_id: &str, request: &ServerRequest) -> Option<UiEvent> {
        let proc = EventProcessor::new();
        let mut rx = proc.subscribe();
        proc.process_server_request(server_id, request);
        rx.try_recv().ok()
    }

    fn make_turn(id: &str) -> proto::Turn {
        proto::Turn {
            id: id.to_string(),
            items: Vec::new(),
            status: proto::TurnStatus::Completed,
            error: None,
        }
    }

    fn make_item(id: &str) -> proto::ThreadItem {
        proto::ThreadItem::AgentMessage {
            id: id.to_string(),
            text: String::new(),
            phase: None,
        }
    }

    fn generated_item_id(item: &generated::ThreadItem) -> &str {
        match item {
            generated::ThreadItem::UserMessage { id, .. }
            | generated::ThreadItem::AgentMessage { id, .. }
            | generated::ThreadItem::Plan { id, .. }
            | generated::ThreadItem::Reasoning { id, .. }
            | generated::ThreadItem::CommandExecution { id, .. }
            | generated::ThreadItem::FileChange { id, .. }
            | generated::ThreadItem::McpToolCall { id, .. }
            | generated::ThreadItem::DynamicToolCall { id, .. }
            | generated::ThreadItem::CollabAgentToolCall { id, .. }
            | generated::ThreadItem::WebSearch { id, .. }
            | generated::ThreadItem::ImageView { id, .. }
            | generated::ThreadItem::ImageGeneration { id, .. }
            | generated::ThreadItem::EnteredReviewMode { id, .. }
            | generated::ThreadItem::ExitedReviewMode { id, .. }
            | generated::ThreadItem::ContextCompaction { id, .. } => id,
        }
    }

    // ── EventProcessor basics ──────────────────────────────────────────

    #[test]
    fn new_processor_has_no_pending_approvals() {
        let proc = EventProcessor::new();
        assert!(proc.pending_approvals().is_empty());
    }

    #[test]
    fn default_creates_same_as_new() {
        let proc = EventProcessor::default();
        assert!(proc.pending_approvals().is_empty());
    }

    #[test]
    fn subscribe_returns_receiver() {
        let proc = EventProcessor::new();
        let _rx = proc.subscribe();
    }

    // ── Turn lifecycle ─────────────────────────────────────────────────

    #[test]
    fn turn_started() {
        let notification = ServerNotification::TurnStarted(proto::TurnStartedNotification {
            thread_id: "thr_1".to_string(),
            turn: make_turn("turn_1"),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::TurnStarted { key, turn_id } => {
                assert_eq!(key.server_id, "srv1");
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(turn_id, "turn_1");
            }
            other => panic!("expected TurnStarted, got {other:?}"),
        }
    }

    #[test]
    fn turn_completed() {
        let notification = ServerNotification::TurnCompleted(proto::TurnCompletedNotification {
            thread_id: "thr_2".to_string(),
            turn: make_turn("turn_2"),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit UiEvent");
        match evt {
            UiEvent::TurnCompleted { key, turn_id } => {
                assert_eq!(key.thread_id, "thr_2");
                assert_eq!(turn_id, "turn_2");
            }
            other => panic!("expected TurnCompleted, got {other:?}"),
        }
    }

    // ── Item lifecycle ─────────────────────────────────────────────────

    #[test]
    fn item_started() {
        let notification = ServerNotification::ItemStarted(proto::ItemStartedNotification {
            thread_id: "thr_1".to_string(),
            turn_id: "turn_1".to_string(),
            item: make_item("item_1"),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ItemStarted { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.turn_id, "turn_1");
                assert_eq!(generated_item_id(&notification.item), "item_1");
            }
            other => panic!("expected ItemStarted, got {other:?}"),
        }
    }

    #[test]
    fn item_completed() {
        let notification = ServerNotification::ItemCompleted(proto::ItemCompletedNotification {
            thread_id: "thr_1".to_string(),
            turn_id: "turn_1".to_string(),
            item: make_item("item_2"),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ItemCompleted { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.turn_id, "turn_1");
                assert_eq!(generated_item_id(&notification.item), "item_2");
            }
            other => panic!("expected ItemCompleted, got {other:?}"),
        }
    }

    // ── Streaming deltas ───────────────────────────────────────────────

    #[test]
    fn agent_message_delta() {
        let notification =
            ServerNotification::AgentMessageDelta(proto::AgentMessageDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "Hello ".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::MessageDelta {
                key,
                item_id,
                delta,
            } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(item_id, "item_1");
                assert_eq!(delta, "Hello ");
            }
            other => panic!("expected MessageDelta, got {other:?}"),
        }
    }

    #[test]
    fn reasoning_text_delta() {
        let notification =
            ServerNotification::ReasoningTextDelta(proto::ReasoningTextDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "thinking...".to_string(),
                content_index: 0,
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ReasoningDelta { delta, .. } => {
                assert_eq!(delta, "thinking...");
            }
            other => panic!("expected ReasoningDelta, got {other:?}"),
        }
    }

    #[test]
    fn reasoning_summary_text_delta() {
        let notification = ServerNotification::ReasoningSummaryTextDelta(
            proto::ReasoningSummaryTextDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "summary...".to_string(),
                summary_index: 0,
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ReasoningDelta { delta, .. } => {
                assert_eq!(delta, "summary...");
            }
            other => panic!("expected ReasoningDelta, got {other:?}"),
        }
    }

    #[test]
    fn plan_delta() {
        let notification = ServerNotification::PlanDelta(proto::PlanDeltaNotification {
            thread_id: "thr_1".to_string(),
            turn_id: "turn_1".to_string(),
            item_id: "item_1".to_string(),
            delta: "step 1".to_string(),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::PlanDelta { delta, .. } => {
                assert_eq!(delta, "step 1");
            }
            other => panic!("expected PlanDelta, got {other:?}"),
        }
    }

    #[test]
    fn command_execution_output_delta() {
        let notification = ServerNotification::CommandExecutionOutputDelta(
            proto::CommandExecutionOutputDeltaNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                delta: "output".to_string(),
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::CommandOutputDelta { delta, .. } => {
                assert_eq!(delta, "output");
            }
            other => panic!("expected CommandOutputDelta, got {other:?}"),
        }
    }

    // ── Realtime / voice ───────────────────────────────────────────────

    #[test]
    fn realtime_started() {
        let notification =
            ServerNotification::ThreadRealtimeStarted(proto::ThreadRealtimeStartedNotification {
                thread_id: "thr_1".to_string(),
                session_id: Some("sess_abc".to_string()),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeStarted { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.session_id.as_deref(), Some("sess_abc"));
            }
            other => panic!("expected RealtimeStarted, got {other:?}"),
        }
    }

    #[test]
    fn realtime_item_added() {
        let item_val = json!({"type": "message", "role": "assistant"});
        let notification = ServerNotification::ThreadRealtimeItemAdded(
            proto::ThreadRealtimeItemAddedNotification {
                thread_id: "thr_1".to_string(),
                item: item_val.clone(),
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeItemAdded { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                let parsed = serde_json::to_value(&notification.item).unwrap();
                assert_eq!(parsed["type"], "message");
            }
            other => panic!("expected RealtimeItemAdded, got {other:?}"),
        }
    }

    #[test]
    fn realtime_audio_delta() {
        let notification = ServerNotification::ThreadRealtimeOutputAudioDelta(
            proto::ThreadRealtimeOutputAudioDeltaNotification {
                thread_id: "thr_1".to_string(),
                audio: proto::ThreadRealtimeAudioChunk {
                    data: "base64audio==".to_string(),
                    sample_rate: 24000,
                    num_channels: 1,
                    samples_per_channel: None,
                },
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeOutputAudioDelta { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.audio.data, "base64audio==");
            }
            other => panic!("expected RealtimeOutputAudioDelta, got {other:?}"),
        }
    }

    // ── Errors ─────────────────────────────────────────────────────────

    #[test]
    fn error_notification() {
        let notification = ServerNotification::Error(proto::ErrorNotification {
            error: proto::TurnError {
                message: "rate limited".to_string(),
                codex_error_info: None,
                additional_details: None,
            },
            will_retry: false,
            thread_id: String::new(),
            turn_id: String::new(),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::Error { message, .. } => {
                assert_eq!(message, "rate limited");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn error_notification_with_thread() {
        let notification = ServerNotification::Error(proto::ErrorNotification {
            error: proto::TurnError {
                message: "oops".to_string(),
                codex_error_info: None,
                additional_details: None,
            },
            will_retry: false,
            thread_id: "thr_1".to_string(),
            turn_id: String::new(),
        });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::Error { key, message, .. } => {
                assert_eq!(key.as_ref().unwrap().thread_id, "thr_1");
                assert_eq!(message, "oops");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn realtime_error_emits_typed_event() {
        let notification =
            ServerNotification::ThreadRealtimeError(proto::ThreadRealtimeErrorNotification {
                thread_id: "thr_1".to_string(),
                message: "voice error".to_string(),
            });
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::RealtimeError { key, notification } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(notification.thread_id, "thr_1");
                assert_eq!(notification.message, "voice error");
            }
            other => panic!("expected RealtimeError, got {other:?}"),
        }
    }

    // ── Context tokens ─────────────────────────────────────────────────

    #[test]
    fn thread_token_usage_updated() {
        let notification = ServerNotification::ThreadTokenUsageUpdated(
            proto::ThreadTokenUsageUpdatedNotification {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                token_usage: proto::ThreadTokenUsage {
                    total: proto::TokenUsageBreakdown {
                        total_tokens: 5000,
                        input_tokens: 3000,
                        cached_input_tokens: 0,
                        output_tokens: 2000,
                        reasoning_output_tokens: 0,
                    },
                    last: proto::TokenUsageBreakdown {
                        total_tokens: 150,
                        input_tokens: 100,
                        cached_input_tokens: 0,
                        output_tokens: 50,
                        reasoning_output_tokens: 0,
                    },
                    model_context_window: Some(128000),
                },
            },
        );
        let evt = process_and_recv("srv1", &notification).expect("should emit");
        match evt {
            UiEvent::ContextTokensUpdated {
                key, used, limit, ..
            } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(used, 5000);
                assert_eq!(limit, 128000);
            }
            other => panic!("expected ContextTokensUpdated, got {other:?}"),
        }
    }

    // ── Unknown notifications ──────────────────────────────────────────

    #[test]
    fn unhandled_known_notification_emits_raw() {
        // SkillsChanged is known but not mapped to a typed UiEvent —
        // it should be forwarded as RawNotification.
        let notification = ServerNotification::SkillsChanged(proto::SkillsChangedNotification {});
        let evt = process_and_recv("srv1", &notification);
        assert!(evt.is_some());
        match evt.unwrap() {
            UiEvent::RawNotification { method, .. } => {
                assert!(!method.is_empty());
            }
            other => panic!("expected RawNotification, got {other:?}"),
        }
    }

    // ── Server requests (approvals) ────────────────────────────────────

    #[test]
    fn command_approval_request() {
        let request = ServerRequest::CommandExecutionRequestApproval {
            request_id: proto::RequestId::Integer(42),
            params: proto::CommandExecutionRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                approval_id: None,
                reason: None,
                network_approval_context: None,
                command: Some("rm -rf /tmp".to_string()),
                cwd: None,
                command_actions: None,
                additional_permissions: None,
                skill_metadata: None,
                proposed_execpolicy_amendment: None,
                proposed_network_policy_amendments: None,
                available_decisions: None,
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { key, approval } => {
                assert_eq!(key.thread_id, "thr_1");
                assert_eq!(approval.kind, ApprovalKind::Command);
                assert_eq!(approval.id, "42");
                assert_eq!(approval.command.as_deref(), Some("rm -rf /tmp"));
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn file_change_approval_request() {
        let request = ServerRequest::FileChangeRequestApproval {
            request_id: proto::RequestId::Integer(10),
            params: proto::FileChangeRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                reason: Some("modify file".to_string()),
                grant_root: None,
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { approval, .. } => {
                assert_eq!(approval.kind, ApprovalKind::FileChange);
                assert_eq!(approval.reason.as_deref(), Some("modify file"));
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn permissions_approval_request() {
        let request = ServerRequest::PermissionsRequestApproval {
            request_id: proto::RequestId::Integer(11),
            params: proto::PermissionsRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                reason: Some("need network access".to_string()),
                permissions: proto::RequestPermissionProfile {
                    network: None,
                    file_system: None,
                },
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { approval, .. } => {
                assert_eq!(approval.kind, ApprovalKind::Permissions);
                assert_eq!(approval.reason.as_deref(), Some("need network access"));
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn mcp_elicitation_request() {
        let request = ServerRequest::McpServerElicitationRequest {
            request_id: proto::RequestId::Integer(12),
            params: proto::McpServerElicitationRequestParams {
                thread_id: "thr_1".to_string(),
                turn_id: None,
                server_name: "test_server".to_string(),
                request: proto::McpServerElicitationRequest::Form {
                    meta: None,
                    message: "Allow?".to_string(),
                    requested_schema: serde_json::from_value(json!({
                        "type": "object",
                        "properties": {}
                    }))
                    .unwrap(),
                },
            },
        };
        let evt = request_and_recv("srv1", &request).expect("should emit");
        match evt {
            UiEvent::ApprovalRequested { approval, .. } => {
                assert_eq!(approval.kind, ApprovalKind::McpElicitation);
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    // ── Pending approval management ────────────────────────────────────

    #[test]
    fn pending_approvals_are_tracked() {
        let proc = EventProcessor::new();
        let req1 = ServerRequest::CommandExecutionRequestApproval {
            request_id: proto::RequestId::Integer(1),
            params: proto::CommandExecutionRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                approval_id: None,
                reason: None,
                network_approval_context: None,
                command: Some("ls".to_string()),
                cwd: None,
                command_actions: None,
                additional_permissions: None,
                skill_metadata: None,
                proposed_execpolicy_amendment: None,
                proposed_network_policy_amendments: None,
                available_decisions: None,
            },
        };
        let req2 = ServerRequest::FileChangeRequestApproval {
            request_id: proto::RequestId::Integer(2),
            params: proto::FileChangeRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_2".to_string(),
                reason: None,
                grant_root: None,
            },
        };
        proc.process_server_request("srv1", &req1);
        proc.process_server_request("srv1", &req2);
        assert_eq!(proc.pending_approvals().len(), 2);
    }

    #[test]
    fn resolve_approval_removes_it() {
        let proc = EventProcessor::new();
        let req1 = ServerRequest::CommandExecutionRequestApproval {
            request_id: proto::RequestId::Integer(1),
            params: proto::CommandExecutionRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_1".to_string(),
                approval_id: None,
                reason: None,
                network_approval_context: None,
                command: None,
                cwd: None,
                command_actions: None,
                additional_permissions: None,
                skill_metadata: None,
                proposed_execpolicy_amendment: None,
                proposed_network_policy_amendments: None,
                available_decisions: None,
            },
        };
        let req2 = ServerRequest::FileChangeRequestApproval {
            request_id: proto::RequestId::Integer(2),
            params: proto::FileChangeRequestApprovalParams {
                thread_id: "thr_1".to_string(),
                turn_id: "turn_1".to_string(),
                item_id: "item_2".to_string(),
                reason: None,
                grant_root: None,
            },
        };
        proc.process_server_request("srv1", &req1);
        proc.process_server_request("srv1", &req2);

        let resolved = proc.resolve_approval("1");
        assert!(resolved.is_some());
        assert_eq!(resolved.unwrap().id, "1");
        assert_eq!(proc.pending_approvals().len(), 1);
        assert_eq!(proc.pending_approvals()[0].id, "2");
    }

    #[test]
    fn resolve_nonexistent_approval_returns_none() {
        let proc = EventProcessor::new();
        assert!(proc.resolve_approval("999").is_none());
    }

    // ── Send + Sync ────────────────────────────────────────────────────

    #[test]
    fn event_processor_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<EventProcessor>();
    }

    // ── Multiple subscribers ───────────────────────────────────────────

    #[test]
    fn multiple_subscribers_receive_events() {
        let proc = EventProcessor::new();
        let mut rx1 = proc.subscribe();
        let mut rx2 = proc.subscribe();

        let notification = ServerNotification::TurnStarted(proto::TurnStartedNotification {
            thread_id: "thr_1".to_string(),
            turn: make_turn("turn_1"),
        });
        proc.process_notification("srv1", &notification);

        assert!(rx1.try_recv().is_ok());
        assert!(rx2.try_recv().is_ok());
    }

    // ── No subscribers does not panic ──────────────────────────────────

    #[test]
    fn emit_without_subscribers_does_not_panic() {
        let proc = EventProcessor::new();
        let notification = ServerNotification::TurnStarted(proto::TurnStartedNotification {
            thread_id: "thr_1".to_string(),
            turn: make_turn("turn_1"),
        });
        proc.process_notification("srv1", &notification);
        // No panic = success.
    }
}
