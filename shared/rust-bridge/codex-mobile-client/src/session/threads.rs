//! Thread lifecycle management: start, resume, fork, rollback, archive.
//!
//! Manages thread state, turn operations, and thread list refresh
//! across multiple connected servers.
//!
//! RPC methods convert mobile param types into upstream typed params via
//! `From` impls, serialize them for the wire, and deserialize responses
//! through upstream typed response structs before converting back to
//! mobile types.

use std::collections::HashMap;

use codex_app_server_protocol as upstream;
use serde_json::Value as JsonValue;
use tracing::{debug, warn};

use crate::session::connection::ServerSession;
use crate::transport::RpcError;
use crate::types::{RateLimits, ThreadInfo, ThreadKey, ThreadSummaryStatus, TurnStatus};

// ---------------------------------------------------------------------------
// ThreadState
// ---------------------------------------------------------------------------

/// Full state of a thread, including active turn tracking.
#[derive(Debug, Clone)]
pub struct ThreadState {
    /// Composite key (server_id + thread_id).
    pub key: ThreadKey,
    /// Summary info from the server.
    pub info: ThreadInfo,
    /// Model in use for this thread, if known.
    pub model: Option<String>,
    /// Current reasoning effort setting.
    pub reasoning_effort: Option<String>,
    /// Active turn, if one is running.
    pub active_turn: Option<ActiveTurn>,
    /// Number of context tokens consumed so far.
    pub context_tokens_used: Option<u64>,
    /// Model's context window size.
    pub model_context_window: Option<u64>,
    /// Rate limit information from the server.
    pub rate_limits: Option<RateLimits>,
}

/// Tracks the state of the currently running turn within a thread.
#[derive(Debug, Clone)]
pub struct ActiveTurn {
    /// Server-assigned turn identifier.
    pub turn_id: String,
    /// Current status of the turn.
    pub status: TurnStatus,
    /// Number of tool calls executed in this turn.
    pub tool_call_count: u32,
    /// Number of file changes made in this turn.
    pub file_change_count: u32,
}

// ---------------------------------------------------------------------------
// ThreadManager
// ---------------------------------------------------------------------------

/// Manages thread lifecycle and state across connected servers.
///
/// Provides methods for RPC-based thread operations (list, start, resume,
/// archive) and local state tracking (active turn, tool/file counters).
pub struct ThreadManager {
    threads: HashMap<ThreadKey, ThreadState>,
    active_thread: Option<ThreadKey>,
}

impl ThreadManager {
    /// Create a new, empty thread manager.
    pub fn new() -> Self {
        Self {
            threads: HashMap::new(),
            active_thread: None,
        }
    }

    // -- RPC operations -----------------------------------------------------

    /// List threads from a server (sends `thread/list` RPC).
    pub async fn list_threads(&self, session: &ServerSession) -> Result<Vec<ThreadInfo>, RpcError> {
        let params = upstream::ThreadListParams {
            limit: None,
            cursor: None,
            sort_key: None,
            model_providers: None,
            source_kinds: None,
            archived: None,
            cwd: None,
            search_term: None,
        };
        let params_value =
            serde_json::to_value(&params).map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let result = session.request("thread/list", params_value).await?;

        let response: upstream::ThreadListResponse =
            serde_json::from_value(result).map_err(|e| {
                RpcError::Deserialization(format!("failed to parse thread/list response: {e}"))
            })?;

        let threads: Vec<ThreadInfo> = response.data.into_iter().map(ThreadInfo::from).collect();
        debug!("list_threads: received {} threads", threads.len());
        Ok(threads)
    }

    /// Start a new thread (sends `thread/start` RPC).
    ///
    /// Creates local `ThreadState` and returns the key on success.
    pub async fn start_thread(
        &mut self,
        session: &ServerSession,
        params: upstream::ThreadStartParams,
    ) -> Result<ThreadKey, RpcError> {
        let params_value =
            serde_json::to_value(&params).map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let result = session.request("thread/start", params_value).await?;

        let response: upstream::ThreadStartResponse =
            serde_json::from_value(result).map_err(|e| {
                RpcError::Deserialization(format!("failed to parse thread/start response: {e}"))
            })?;

        let key = ThreadKey {
            server_id: session.config().server_id.clone(),
            thread_id: response.thread.id.clone(),
        };

        let state = ThreadState {
            key: key.clone(),
            info: ThreadInfo::from(response.thread),
            model: Some(response.model),
            reasoning_effort: None,
            active_turn: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
        };

        debug!("start_thread: created thread {}", key.thread_id);
        self.threads.insert(key.clone(), state);
        self.active_thread = Some(key.clone());
        Ok(key)
    }

    /// Resume an existing thread (sends `thread/resume` RPC).
    ///
    /// Creates or updates local `ThreadState` and returns the key.
    pub async fn resume_thread(
        &mut self,
        session: &ServerSession,
        thread_id: &str,
    ) -> Result<ThreadKey, RpcError> {
        let params = upstream::ThreadResumeParams {
            thread_id: thread_id.to_string(),
            ..Default::default()
        };
        let params_value =
            serde_json::to_value(&params).map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let result = session.request("thread/resume", params_value).await?;

        let response: upstream::ThreadResumeResponse =
            serde_json::from_value(result).map_err(|e| {
                RpcError::Deserialization(format!("failed to parse thread/resume response: {e}"))
            })?;

        let key = ThreadKey {
            server_id: session.config().server_id.clone(),
            thread_id: response.thread.id.clone(),
        };

        let state = ThreadState {
            key: key.clone(),
            info: ThreadInfo::from(response.thread),
            model: Some(response.model),
            reasoning_effort: None,
            active_turn: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
        };

        debug!("resume_thread: resumed thread {}", key.thread_id);
        self.threads.insert(key.clone(), state);
        self.active_thread = Some(key.clone());
        Ok(key)
    }

    /// Send a message / start a turn (sends `turn/start` RPC).
    pub async fn send_message(
        &mut self,
        session: &ServerSession,
        key: &ThreadKey,
        params: upstream::TurnStartParams,
    ) -> Result<(), RpcError> {
        let params_value =
            serde_json::to_value(&params).map_err(|e| RpcError::Deserialization(e.to_string()))?;

        session.request("turn/start", params_value).await?;

        // Mark thread as active.
        if let Some(state) = self.threads.get_mut(key) {
            state.info.status = ThreadSummaryStatus::Active;
        }

        debug!("send_message: turn started on thread {}", key.thread_id);
        Ok(())
    }

    /// Interrupt an active turn (sends `turn/interrupt` RPC).
    pub async fn interrupt_turn(
        &self,
        session: &ServerSession,
        key: &ThreadKey,
    ) -> Result<(), RpcError> {
        let params = upstream::TurnInterruptParams {
            thread_id: key.thread_id.clone(),
            turn_id: String::new(),
        };
        let params_value =
            serde_json::to_value(&params).map_err(|e| RpcError::Deserialization(e.to_string()))?;

        session.request("turn/interrupt", params_value).await?;

        debug!(
            "interrupt_turn: interrupted turn on thread {}",
            key.thread_id
        );
        Ok(())
    }

    /// Archive a thread (sends `thread/archive` RPC).
    ///
    /// Removes the thread from local state on success.
    pub async fn archive_thread(
        &mut self,
        session: &ServerSession,
        key: &ThreadKey,
    ) -> Result<(), RpcError> {
        let params = upstream::ThreadArchiveParams {
            thread_id: key.thread_id.clone(),
        };
        let params_value =
            serde_json::to_value(&params).map_err(|e| RpcError::Deserialization(e.to_string()))?;

        session.request("thread/archive", params_value).await?;

        // Remove from local state.
        self.threads.remove(key);
        if self.active_thread.as_ref() == Some(key) {
            self.active_thread = None;
        }

        debug!("archive_thread: archived thread {}", key.thread_id);
        Ok(())
    }

    // -- Local state accessors ----------------------------------------------

    /// Set the active thread. Pass `None` to clear.
    pub fn set_active_thread(&mut self, key: Option<ThreadKey>) {
        self.active_thread = key;
    }

    /// Get the active thread state, if any.
    pub fn active_thread(&self) -> Option<&ThreadState> {
        self.active_thread
            .as_ref()
            .and_then(|k| self.threads.get(k))
    }

    /// Get thread state by key.
    pub fn thread(&self, key: &ThreadKey) -> Option<&ThreadState> {
        self.threads.get(key)
    }

    /// Get mutable thread state by key.
    pub fn thread_mut(&mut self, key: &ThreadKey) -> Option<&mut ThreadState> {
        self.threads.get_mut(key)
    }

    /// All tracked threads.
    pub fn all_threads(&self) -> &HashMap<ThreadKey, ThreadState> {
        &self.threads
    }

    // -- Notification-driven state updates ----------------------------------

    /// Update thread state from notification data (called by event processor).
    ///
    /// Extracts known fields from the JSON payload and applies them to
    /// the corresponding `ThreadState`.
    pub fn update_thread_from_notification(&mut self, key: &ThreadKey, data: &JsonValue) {
        let Some(state) = self.threads.get_mut(key) else {
            warn!(
                "update_thread_from_notification: unknown thread {}",
                key.thread_id
            );
            return;
        };

        if let Some(title) = data.get("title").and_then(|v| v.as_str()) {
            state.info.title = Some(title.to_string());
        }

        if let Some(status_str) = data.get("status").and_then(|v| v.as_str()) {
            if let Ok(status) = serde_json::from_value(JsonValue::String(status_str.to_string())) {
                state.info.status = status;
            }
        }

        if let Some(model) = data.get("model").and_then(|v| v.as_str()) {
            state.model = Some(model.to_string());
        }

        if let Some(tokens) = data.get("contextTokensUsed").and_then(|v| v.as_u64()) {
            state.context_tokens_used = Some(tokens);
        }

        if let Some(window) = data.get("modelContextWindow").and_then(|v| v.as_u64()) {
            state.model_context_window = Some(window);
        }

        if let Some(limits) = data.get("rateLimits") {
            if let Ok(parsed) = serde_json::from_value::<RateLimits>(limits.clone()) {
                state.rate_limits = Some(parsed);
            }
        }
    }

    // -- Turn lifecycle helpers ---------------------------------------------

    /// Mark a turn as started on the given thread.
    pub fn turn_started(&mut self, key: &ThreadKey, turn_id: String) {
        if let Some(state) = self.threads.get_mut(key) {
            state.active_turn = Some(ActiveTurn {
                turn_id,
                status: TurnStatus::Running,
                tool_call_count: 0,
                file_change_count: 0,
            });
            state.info.status = ThreadSummaryStatus::Active;
        }
    }

    /// Mark a turn as completed on the given thread.
    pub fn turn_completed(&mut self, key: &ThreadKey) {
        if let Some(state) = self.threads.get_mut(key) {
            if let Some(turn) = &mut state.active_turn {
                turn.status = TurnStatus::Completed;
            }
            state.active_turn = None;
            state.info.status = ThreadSummaryStatus::Idle;
        }
    }

    /// Increment the tool call count for the active turn.
    pub fn increment_tool_calls(&mut self, key: &ThreadKey) {
        if let Some(state) = self.threads.get_mut(key) {
            if let Some(turn) = &mut state.active_turn {
                turn.tool_call_count += 1;
            }
        }
    }

    /// Increment the file change count for the active turn.
    pub fn increment_file_changes(&mut self, key: &ThreadKey) {
        if let Some(state) = self.threads.get_mut(key) {
            if let Some(turn) = &mut state.active_turn {
                turn.file_change_count += 1;
            }
        }
    }
}

impl Default for ThreadManager {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn make_key(server: &str, thread: &str) -> ThreadKey {
        ThreadKey {
            server_id: server.to_string(),
            thread_id: thread.to_string(),
        }
    }

    fn make_thread_info(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: None,
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            created_at: None,
            updated_at: None,
        }
    }

    fn insert_thread(mgr: &mut ThreadManager, server: &str, thread_id: &str) -> ThreadKey {
        let key = make_key(server, thread_id);
        let state = ThreadState {
            key: key.clone(),
            info: make_thread_info(thread_id),
            model: None,
            reasoning_effort: None,
            active_turn: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
        };
        mgr.threads.insert(key.clone(), state);
        key
    }

    // -- Constructor tests --

    #[test]
    fn new_manager_is_empty() {
        let mgr = ThreadManager::new();
        assert!(mgr.all_threads().is_empty());
        assert!(mgr.active_thread().is_none());
    }

    #[test]
    fn default_is_same_as_new() {
        let mgr = ThreadManager::default();
        assert!(mgr.all_threads().is_empty());
        assert!(mgr.active_thread().is_none());
    }

    // -- Active thread tests --

    #[test]
    fn set_active_thread() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        mgr.set_active_thread(Some(key.clone()));
        assert!(mgr.active_thread().is_some());
        assert_eq!(mgr.active_thread().unwrap().key, key);
    }

    #[test]
    fn clear_active_thread() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");
        mgr.set_active_thread(Some(key));

        mgr.set_active_thread(None);
        assert!(mgr.active_thread().is_none());
    }

    #[test]
    fn active_thread_returns_none_for_missing_key() {
        let mut mgr = ThreadManager::new();
        let key = make_key("srv1", "nonexistent");
        mgr.set_active_thread(Some(key));
        // Key is set but thread doesn't exist in the map.
        assert!(mgr.active_thread().is_none());
    }

    // -- Thread lookup tests --

    #[test]
    fn thread_lookup_by_key() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_abc");
        assert!(mgr.thread(&key).is_some());
        assert_eq!(mgr.thread(&key).unwrap().info.id, "thr_abc");
    }

    #[test]
    fn thread_lookup_missing_returns_none() {
        let mgr = ThreadManager::new();
        let key = make_key("srv1", "missing");
        assert!(mgr.thread(&key).is_none());
    }

    #[test]
    fn thread_mut_can_modify_state() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        mgr.thread_mut(&key).unwrap().model = Some("o4-mini".to_string());
        assert_eq!(mgr.thread(&key).unwrap().model, Some("o4-mini".to_string()));
    }

    #[test]
    fn all_threads_returns_all() {
        let mut mgr = ThreadManager::new();
        insert_thread(&mut mgr, "srv1", "thr_1");
        insert_thread(&mut mgr, "srv1", "thr_2");
        insert_thread(&mut mgr, "srv2", "thr_3");
        assert_eq!(mgr.all_threads().len(), 3);
    }

    // -- Turn lifecycle tests --

    #[test]
    fn turn_started_creates_active_turn() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        mgr.turn_started(&key, "turn_001".to_string());

        let state = mgr.thread(&key).unwrap();
        assert!(state.active_turn.is_some());
        let turn = state.active_turn.as_ref().unwrap();
        assert_eq!(turn.turn_id, "turn_001");
        assert_eq!(turn.status, TurnStatus::Running);
        assert_eq!(turn.tool_call_count, 0);
        assert_eq!(turn.file_change_count, 0);
        assert_eq!(state.info.status, ThreadSummaryStatus::Active);
    }

    #[test]
    fn turn_completed_clears_active_turn() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        mgr.turn_started(&key, "turn_001".to_string());
        mgr.turn_completed(&key);

        let state = mgr.thread(&key).unwrap();
        assert!(state.active_turn.is_none());
        assert_eq!(state.info.status, ThreadSummaryStatus::Idle);
    }

    #[test]
    fn turn_completed_on_idle_thread_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        // No active turn — should not panic.
        mgr.turn_completed(&key);
        let state = mgr.thread(&key).unwrap();
        assert!(state.active_turn.is_none());
        assert_eq!(state.info.status, ThreadSummaryStatus::Idle);
    }

    #[test]
    fn turn_started_on_missing_thread_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = make_key("srv1", "missing");
        // Should not panic.
        mgr.turn_started(&key, "turn_001".to_string());
    }

    // -- Tool/file counter tests --

    #[test]
    fn increment_tool_calls() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");
        mgr.turn_started(&key, "turn_001".to_string());

        mgr.increment_tool_calls(&key);
        mgr.increment_tool_calls(&key);
        mgr.increment_tool_calls(&key);

        let turn = mgr.thread(&key).unwrap().active_turn.as_ref().unwrap();
        assert_eq!(turn.tool_call_count, 3);
    }

    #[test]
    fn increment_file_changes() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");
        mgr.turn_started(&key, "turn_001".to_string());

        mgr.increment_file_changes(&key);
        mgr.increment_file_changes(&key);

        let turn = mgr.thread(&key).unwrap().active_turn.as_ref().unwrap();
        assert_eq!(turn.file_change_count, 2);
    }

    #[test]
    fn increment_tool_calls_without_active_turn_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");
        // No active turn.
        mgr.increment_tool_calls(&key);
        assert!(mgr.thread(&key).unwrap().active_turn.is_none());
    }

    #[test]
    fn increment_file_changes_without_active_turn_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");
        mgr.increment_file_changes(&key);
        assert!(mgr.thread(&key).unwrap().active_turn.is_none());
    }

    #[test]
    fn increment_on_missing_thread_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = make_key("srv1", "missing");
        mgr.increment_tool_calls(&key);
        mgr.increment_file_changes(&key);
    }

    // -- Notification update tests --

    #[test]
    fn update_thread_from_notification_title() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({"title": "New Title"});
        mgr.update_thread_from_notification(&key, &data);

        assert_eq!(
            mgr.thread(&key).unwrap().info.title,
            Some("New Title".to_string())
        );
    }

    #[test]
    fn update_thread_from_notification_status() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({"status": "active"});
        mgr.update_thread_from_notification(&key, &data);

        assert_eq!(mgr.thread(&key).unwrap().info.status, ThreadSummaryStatus::Active);
    }

    #[test]
    fn update_thread_from_notification_model() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({"model": "o4-mini"});
        mgr.update_thread_from_notification(&key, &data);

        assert_eq!(mgr.thread(&key).unwrap().model, Some("o4-mini".to_string()));
    }

    #[test]
    fn update_thread_from_notification_context_tokens() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({"contextTokensUsed": 5000, "modelContextWindow": 128000});
        mgr.update_thread_from_notification(&key, &data);

        let state = mgr.thread(&key).unwrap();
        assert_eq!(state.context_tokens_used, Some(5000));
        assert_eq!(state.model_context_window, Some(128000));
    }

    #[test]
    fn update_thread_from_notification_rate_limits() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({
            "rateLimits": {
                "requestsRemaining": 100,
                "tokensRemaining": 50000,
                "resetAt": "2026-03-20T12:00:00Z"
            }
        });
        mgr.update_thread_from_notification(&key, &data);

        let limits = mgr.thread(&key).unwrap().rate_limits.as_ref().unwrap();
        assert_eq!(limits.requests_remaining, Some(100));
        assert_eq!(limits.tokens_remaining, Some(50000));
    }

    #[test]
    fn update_thread_from_notification_missing_thread_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = make_key("srv1", "missing");
        let data = json!({"title": "Doesn't matter"});
        // Should not panic.
        mgr.update_thread_from_notification(&key, &data);
    }

    #[test]
    fn update_thread_from_notification_invalid_status_ignored() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({"status": "bogusStatus"});
        mgr.update_thread_from_notification(&key, &data);

        // Status should remain the original.
        assert_eq!(mgr.thread(&key).unwrap().info.status, ThreadSummaryStatus::Idle);
    }

    #[test]
    fn update_thread_from_notification_empty_data_is_noop() {
        let mut mgr = ThreadManager::new();
        let key = insert_thread(&mut mgr, "srv1", "thr_1");

        let data = json!({});
        mgr.update_thread_from_notification(&key, &data);

        let state = mgr.thread(&key).unwrap();
        assert!(state.info.title.is_none());
        assert!(state.model.is_none());
    }

    // -- Multi-thread switching tests --

    #[test]
    fn switch_between_threads() {
        let mut mgr = ThreadManager::new();
        let key1 = insert_thread(&mut mgr, "srv1", "thr_1");
        let key2 = insert_thread(&mut mgr, "srv1", "thr_2");

        mgr.set_active_thread(Some(key1.clone()));
        assert_eq!(mgr.active_thread().unwrap().key, key1);

        mgr.set_active_thread(Some(key2.clone()));
        assert_eq!(mgr.active_thread().unwrap().key, key2);
    }

    #[test]
    fn turn_lifecycle_across_threads() {
        let mut mgr = ThreadManager::new();
        let key1 = insert_thread(&mut mgr, "srv1", "thr_1");
        let key2 = insert_thread(&mut mgr, "srv1", "thr_2");

        // Start turn on thread 1.
        mgr.turn_started(&key1, "turn_a".to_string());
        mgr.increment_tool_calls(&key1);

        // Start turn on thread 2 — thread 1 should remain unaffected.
        mgr.turn_started(&key2, "turn_b".to_string());
        mgr.increment_file_changes(&key2);

        let t1 = mgr.thread(&key1).unwrap().active_turn.as_ref().unwrap();
        assert_eq!(t1.turn_id, "turn_a");
        assert_eq!(t1.tool_call_count, 1);
        assert_eq!(t1.file_change_count, 0);

        let t2 = mgr.thread(&key2).unwrap().active_turn.as_ref().unwrap();
        assert_eq!(t2.turn_id, "turn_b");
        assert_eq!(t2.tool_call_count, 0);
        assert_eq!(t2.file_change_count, 1);

        // Complete thread 1 — thread 2 remains active.
        mgr.turn_completed(&key1);
        assert!(mgr.thread(&key1).unwrap().active_turn.is_none());
        assert!(mgr.thread(&key2).unwrap().active_turn.is_some());
    }

    // -- Integration tests (require a real server) --------------------------

    #[tokio::test]
    #[ignore]
    async fn integration_list_threads() {
        // Requires a running Codex server.
        // let session = ServerSession::connect_remote(...).await.unwrap();
        // let mgr = ThreadManager::new();
        // let threads = mgr.list_threads(&session).await.unwrap();
        // assert!(!threads.is_empty());
    }

    #[tokio::test]
    #[ignore]
    async fn integration_start_and_archive_thread() {
        // Requires a running Codex server.
        // let session = ServerSession::connect_remote(...).await.unwrap();
        // let mut mgr = ThreadManager::new();
        // let key = mgr.start_thread(&session, ThreadStartParams { ... }).await.unwrap();
        // mgr.archive_thread(&session, &key).await.unwrap();
        // assert!(mgr.thread(&key).is_none());
    }
}
