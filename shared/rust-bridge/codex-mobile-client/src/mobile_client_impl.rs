use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, RwLock};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::session::connection::InProcessConfig;
use crate::session::connection::{ServerConfig, ServerEvent, ServerSession};
use crate::session::events::{EventProcessor, UiEvent};
use crate::store::{AppSnapshot, AppStoreReducer, AppUpdate, ServerHealthSnapshot, ThreadSnapshot};
use crate::transport::{RpcError, TransportError};
use crate::types::{
    ApprovalDecisionValue, PendingApproval, PendingUserInputAnswer, PendingUserInputRequest,
    ThreadInfo, ThreadKey, ThreadSummaryStatus, generated,
};
use codex_app_server_protocol as upstream;

/// Top-level entry point for platform code (iOS / Android).
///
/// Ties together server sessions, thread management, event processing,
/// discovery, auth, caching, and voice handoff into a single facade.
/// All methods are safe to call from any thread (`Send + Sync`).
pub struct MobileClient {
    pub(crate) sessions: RwLock<HashMap<String, Arc<ServerSession>>>,
    pub(crate) event_processor: Arc<EventProcessor>,
    pub(crate) app_store: Arc<AppStoreReducer>,
    pub(crate) discovery: RwLock<DiscoveryService>,
}

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        let event_processor = Arc::new(EventProcessor::new());
        let app_store = Arc::new(AppStoreReducer::new());
        spawn_store_listener(Arc::clone(&app_store), event_processor.subscribe());
        Self {
            sessions: RwLock::new(HashMap::new()),
            event_processor,
            app_store,
            discovery: RwLock::new(DiscoveryService::new(DiscoveryConfig::default())),
        }
    }

    // ── Server Management ─────────────────────────────────────────────

    /// Connect to a local (in-process) Codex server.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_local(
        &self,
        config: ServerConfig,
        in_process: InProcessConfig,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        let session = Arc::new(ServerSession::connect_local(config, in_process).await?);
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));

        self.sessions
            .write()
            .expect("sessions lock poisoned")
            .insert(server_id.clone(), session);

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }

        info!("MobileClient: connected local server {server_id}");
        Ok(server_id)
    }

    /// Connect to a remote Codex server via WebSocket.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_remote(&self, config: ServerConfig) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        let session = Arc::new(ServerSession::connect_remote(config).await?);
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));

        self.sessions
            .write()
            .expect("sessions lock poisoned")
            .insert(server_id.clone(), session);

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }

        info!("MobileClient: connected remote server {server_id}");
        Ok(server_id)
    }

    /// Disconnect a server by its ID.
    pub fn disconnect_server(&self, server_id: &str) {
        let session = self
            .sessions
            .write()
            .expect("sessions lock poisoned")
            .remove(server_id);

        if let Some(session) = session {
            // Swift/Kotlin can call this from outside any Tokio runtime.
            self.app_store.remove_server(server_id);
            Self::spawn_detached(async move {
                session.disconnect().await;
            });
            info!("MobileClient: disconnected server {server_id}");
        } else {
            warn!("MobileClient: disconnect_server called for unknown {server_id}");
        }
    }

    /// Return the configs of all currently connected servers.
    #[cfg(test)]
    pub(crate) fn connected_servers(&self) -> Vec<ServerConfig> {
        self.sessions
            .read()
            .expect("sessions lock poisoned")
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    // ── Threads ───────────────────────────────────────────────────────

    /// List threads from a specific server.
    #[cfg(test)]
    pub(crate) async fn list_threads(&self, server_id: &str) -> Result<Vec<ThreadInfo>, RpcError> {
        self.get_session(server_id)?;
        let response = self
            .generated_thread_list(
                server_id,
                generated::ThreadListParams {
                    limit: None,
                    cursor: None,
                    sort_key: None,
                    model_providers: None,
                    source_kinds: None,
                    archived: None,
                    cwd: None,
                    search_term: None,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        let threads = response
            .data
            .into_iter()
            .filter_map(thread_info_from_generated_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub async fn sync_server_account(&self, server_id: &str) -> Result<(), RpcError> {
        self.get_session(server_id)?;
        let response = self
            .generated_get_account(
                server_id,
                generated::GetAccountParams {
                    refresh_token: false,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        self.apply_account_response(server_id, &response);
        Ok(())
    }

    /// Roll back the current thread to a selected user turn and return the
    /// message text that should be restored into the composer for editing.
    pub async fn edit_message(
        &self,
        key: &ThreadKey,
        selected_turn_index: u32,
    ) -> Result<String, RpcError> {
        self.get_session(&key.server_id)?;
        let current = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&current)?;
        let rollback_depth = rollback_depth_for_turn(&current, selected_turn_index as usize)?;
        let prefill_text = user_boundary_text_for_turn(&current, selected_turn_index as usize)?;

        if rollback_depth > 0 {
            let response = self
                .generated_thread_rollback(
                    &key.server_id,
                    generated::ThreadRollbackParams {
                        thread_id: key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            let mut snapshot = thread_snapshot_from_generated_thread(
                &key.server_id,
                response.thread,
                current.model.clone(),
                current.reasoning_effort.clone(),
            )
            .map_err(RpcError::Deserialization)?;
            copy_thread_runtime_fields(&current, &mut snapshot);
            self.app_store.upsert_thread_snapshot(snapshot);
        }

        self.set_active_thread(Some(key.clone()));
        Ok(prefill_text)
    }

    /// Fork a thread from a selected user message boundary.
    pub async fn fork_thread_from_message(
        &self,
        key: &ThreadKey,
        selected_turn_index: u32,
        cwd: Option<String>,
        model: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
        persist_extended_history: bool,
    ) -> Result<ThreadKey, RpcError> {
        self.get_session(&key.server_id)?;
        let source = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&source)?;
        let rollback_depth = rollback_depth_for_turn(&source, selected_turn_index as usize)?;

        let response = self
            .generated_thread_fork(
                &key.server_id,
                generated::ThreadForkParams {
                    thread_id: key.thread_id.clone(),
                    path: None,
                    model,
                    model_provider: None,
                    service_tier: None,
                    cwd,
                    approval_policy,
                    approvals_reviewer: None,
                    sandbox,
                    config: None,
                    base_instructions: None,
                    developer_instructions,
                    ephemeral: false,
                    persist_extended_history,
                },
            )
            .await
            .map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let fork_model = Some(response.model);
        let fork_reasoning = response
            .reasoning_effort
            .map(reasoning_effort_string);
        let mut snapshot = thread_snapshot_from_generated_thread(
            &key.server_id,
            response.thread,
            fork_model.clone(),
            fork_reasoning.clone(),
        )
        .map_err(RpcError::Deserialization)?;
        let next_key = snapshot.key.clone();

        if rollback_depth > 0 {
            let rollback_response = self
                .generated_thread_rollback(
                    &key.server_id,
                    generated::ThreadRollbackParams {
                        thread_id: next_key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            snapshot = thread_snapshot_from_generated_thread(
                &key.server_id,
                rollback_response.thread,
                fork_model,
                fork_reasoning,
            )
            .map_err(RpcError::Deserialization)?;
        }

        self.app_store.upsert_thread_snapshot(snapshot);
        self.set_active_thread(Some(next_key.clone()));
        Ok(next_key)
    }

    pub async fn respond_to_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecisionValue,
    ) -> Result<(), RpcError> {
        let approval = self.pending_approval(request_id)?;
        let session = self.get_session(&approval.server_id)?;
        let response_json = approval_response_json(&approval, decision)?;
        session
            .respond(
                serde_json::Value::String(approval.id.clone()),
                response_json,
            )
            .await?;
        debug!(
            "MobileClient: approval response sent for server={} request_id={}",
            approval.server_id, request_id
        );
        self.app_store.resolve_approval(request_id);
        Ok(())
    }

    pub async fn respond_to_user_input(
        &self,
        request_id: &str,
        answers: Vec<PendingUserInputAnswer>,
    ) -> Result<(), RpcError> {
        let request = self.pending_user_input(request_id)?;
        let session = self.get_session(&request.server_id)?;
        let response = generated::ToolRequestUserInputResponse {
            answers: answers
                .into_iter()
                .map(|answer| generated::ToolRequestUserInputResponseAnswersEntry {
                    key: answer.question_id,
                    value: generated::ToolRequestUserInputAnswer {
                        answers: answer.answers,
                    },
                })
                .collect(),
        };
        let response_json = serde_json::to_value(response)
            .map_err(|e| RpcError::Deserialization(format!("serialize user input response: {e}")))?;
        session
            .respond(
                serde_json::Value::String(request.id.clone()),
                response_json,
            )
            .await?;
        debug!(
            "MobileClient: user input response sent for server={} request_id={}",
            request.server_id, request_id
        );
        self.app_store.resolve_pending_user_input(request_id);
        Ok(())
    }

    pub(crate) fn validate_login_account_target(
        &self,
        server_id: &str,
        params: &generated::LoginAccountParams,
    ) -> Result<(), String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        if session.config().is_local {
            return Ok(());
        }

        match params {
            generated::LoginAccountParams::ApiKey { .. } => Err(
                "API keys can only be saved on the local server.".to_string(),
            ),
            generated::LoginAccountParams::ChatgptAuthTokens { .. } => Err(
                "Local ChatGPT tokens can only be sent to the local server.".to_string(),
            ),
            generated::LoginAccountParams::Chatgpt => Ok(()),
        }
    }

    pub fn snapshot(&self) -> AppSnapshot {
        self.app_store.snapshot()
    }

    pub fn subscribe_updates(&self) -> broadcast::Receiver<AppUpdate> {
        self.app_store.subscribe()
    }

    pub fn app_snapshot(&self) -> AppSnapshot {
        self.snapshot()
    }

    pub fn subscribe_app_updates(&self) -> broadcast::Receiver<AppUpdate> {
        self.subscribe_updates()
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_active_thread(key);
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_voice_handoff_thread(key);
    }

    pub async fn scan_servers_with_mdns_context(
        &self,
        mdns_results: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Vec<DiscoveredServer> {
        let mut discovery = self.discovery.write().expect("discovery lock poisoned");
        discovery
            .scan_once_with_context(&mdns_results, local_ipv4.as_deref())
            .await
    }

    fn spawn_event_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let mut events = session.events();
        let processor = Arc::clone(&self.event_processor);
        Self::spawn_detached(async move {
            loop {
                match events.recv().await {
                    Ok(ServerEvent::Notification(notification)) => {
                        processor.process_notification(&server_id, &notification);
                    }
                    Ok(ServerEvent::LegacyNotification { method, params }) => {
                        processor.process_legacy_notification(&server_id, &method, &params);
                    }
                    Ok(ServerEvent::Request(request)) => {
                        processor.process_server_request(&server_id, &request);
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        debug!("MobileClient: event stream closed for {server_id}");
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!("MobileClient: lagged {skipped} events for {server_id}");
                    }
                }
            }
        });
    }

    pub(crate) fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions
            .read()
            .expect("sessions lock poisoned")
            .get(server_id)
            .cloned()
            .ok_or_else(|| RpcError::Transport(TransportError::Disconnected))
    }

    /// Send a raw `ClientRequest` and return the JSON response value.
    /// Used by tooling (e.g. fixture export) that needs raw upstream data.
    pub async fn request_raw_for_server(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<serde_json::Value, String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session
            .request_client(request)
            .await
            .map_err(|e| e.to_string())
    }

    /// Return the configs of all currently connected servers (public for tooling).
    pub fn connected_server_configs(&self) -> Vec<ServerConfig> {
        self.sessions
            .read()
            .expect("sessions lock poisoned")
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    pub(crate) fn snapshot_thread(&self, key: &ThreadKey) -> Result<ThreadSnapshot, RpcError> {
        self.app_store
            .snapshot()
            .threads
            .get(key)
            .cloned()
            .ok_or_else(|| RpcError::Deserialization(format!("unknown thread {}", key.thread_id)))
    }

    pub(crate) async fn request_typed_for_server<R>(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<R, String>
    where
        R: serde::de::DeserializeOwned,
    {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        let value = session
            .request_client(request)
            .await
            .map_err(|e| e.to_string())?;
        serde_json::from_value(value)
            .map_err(|e| format!("deserialize typed RPC response: {e}"))
    }

    fn pending_approval(&self, request_id: &str) -> Result<PendingApproval, RpcError> {
        self.app_store
            .snapshot()
            .pending_approvals
            .into_iter()
            .find(|approval| approval.id == request_id)
            .ok_or_else(|| RpcError::Deserialization(format!("unknown approval request {request_id}")))
    }

    fn pending_user_input(&self, request_id: &str) -> Result<PendingUserInputRequest, RpcError> {
        self.app_store
            .snapshot()
            .pending_user_inputs
            .into_iter()
            .find(|request| request.id == request_id)
            .ok_or_else(|| RpcError::Deserialization(format!("unknown user input request {request_id}")))
    }

    pub(crate) fn spawn_detached<F>(future: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(future);
        } else {
            std::thread::spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("create detached runtime");
                runtime.block_on(future);
            });
        }
    }
}

impl Default for MobileClient {
    fn default() -> Self {
        Self::new()
    }
}

fn spawn_store_listener(
    app_store: Arc<AppStoreReducer>,
    mut rx: broadcast::Receiver<UiEvent>,
) {
    MobileClient::spawn_detached(async move {
        loop {
            match rx.recv().await {
                Ok(event) => app_store.apply_ui_event(&event),
                Err(broadcast::error::RecvError::Closed) => break,
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    warn!("MobileClient: lagged {skipped} UI events");
                }
            }
        }
    });
}

pub fn thread_info_from_generated_thread(
    thread: generated::Thread,
) -> Option<ThreadInfo> {
    thread_info_from_generated_thread_list_item(thread, None, None)
}

fn thread_info_from_generated_thread_list_item(
    thread: generated::Thread,
    model: Option<String>,
    _reasoning_effort: Option<String>,
) -> Option<ThreadInfo> {
    let upstream_thread: upstream::Thread = crate::rpc::convert_generated_field(thread).ok()?;
    let mut info = ThreadInfo::from(upstream_thread);
    info.model = model;
    Some(info)
}

pub fn thread_snapshot_from_generated_thread(
    server_id: &str,
    thread: generated::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
) -> Result<ThreadSnapshot, String> {
    let upstream_thread: upstream::Thread =
        crate::rpc::convert_generated_field(thread).map_err(|e| e.to_string())?;
    let info = ThreadInfo::from(upstream_thread.clone());
    let items = crate::conversation::hydrate_turns(&upstream_thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot.model = model;
    snapshot.reasoning_effort = reasoning_effort;
    Ok(snapshot)
}

pub fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    target.active_turn_id = source.active_turn_id.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
}

fn ensure_thread_is_editable(snapshot: &ThreadSnapshot) -> Result<(), RpcError> {
    if snapshot.items.is_empty() {
        return Err(RpcError::Deserialization("thread has no conversation items".to_string()));
    }
    Ok(())
}

fn rollback_depth_for_turn(snapshot: &ThreadSnapshot, selected_turn_index: usize) -> Result<u32, RpcError> {
    let user_turn_indices = snapshot
        .items
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            matches!(
                item.content,
                crate::conversation::ConversationItemContent::User(_)
            )
            .then_some(idx)
        })
        .collect::<Vec<_>>();
    let item_index = *user_turn_indices.get(selected_turn_index).ok_or_else(|| {
        RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
    })?;
    let turns_after = snapshot.items.len().saturating_sub(item_index + 1);
    u32::try_from(turns_after)
        .map_err(|_| RpcError::Deserialization("rollback depth overflow".to_string()))
}

fn user_boundary_text_for_turn(snapshot: &ThreadSnapshot, selected_turn_index: usize) -> Result<String, RpcError> {
    let item = snapshot
        .items
        .iter()
        .filter(|item| matches!(item.content, crate::conversation::ConversationItemContent::User(_)))
        .nth(selected_turn_index)
        .ok_or_else(|| RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index)))?;
    match &item.content {
        crate::conversation::ConversationItemContent::User(data) => Ok(data.text.clone()),
        _ => Err(RpcError::Deserialization(
            "selected turn has no editable text".to_string(),
        )),
    }
}

pub fn reasoning_effort_string(value: generated::ReasoningEffort) -> String {
    match value {
        generated::ReasoningEffort::None => "none".to_string(),
        generated::ReasoningEffort::Minimal => "minimal".to_string(),
        generated::ReasoningEffort::Low => "low".to_string(),
        generated::ReasoningEffort::Medium => "medium".to_string(),
        generated::ReasoningEffort::High => "high".to_string(),
        generated::ReasoningEffort::XHigh => "xhigh".to_string(),
    }
}

pub fn reasoning_effort_from_string(value: &str) -> Option<generated::ReasoningEffort> {
    match value.trim().to_ascii_lowercase().as_str() {
        "none" => Some(generated::ReasoningEffort::None),
        "minimal" => Some(generated::ReasoningEffort::Minimal),
        "low" => Some(generated::ReasoningEffort::Low),
        "medium" => Some(generated::ReasoningEffort::Medium),
        "high" => Some(generated::ReasoningEffort::High),
        "xhigh" => Some(generated::ReasoningEffort::XHigh),
        _ => None,
    }
}

fn map_transport_error(error: TransportError) -> RpcError {
    RpcError::Transport(error)
}

fn map_rpc_client_error(error: crate::rpc::RpcClientError) -> RpcError {
    match error {
        crate::rpc::RpcClientError::Rpc(message)
        | crate::rpc::RpcClientError::Serialization(message) => {
            RpcError::Deserialization(message)
        }
    }
}

fn approval_response_json(
    approval: &PendingApproval,
    decision: ApprovalDecisionValue,
) -> Result<serde_json::Value, RpcError> {
    match approval.kind {
        crate::types::ApprovalKind::Command => serde_json::to_value(
            generated::CommandExecutionRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => {
                        generated::CommandExecutionApprovalDecision::Accept
                    }
                    ApprovalDecisionValue::AcceptForSession => {
                        generated::CommandExecutionApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        generated::CommandExecutionApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => {
                        generated::CommandExecutionApprovalDecision::Cancel
                    }
                },
            },
        ),
        crate::types::ApprovalKind::FileChange => serde_json::to_value(
            generated::FileChangeRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => generated::FileChangeApprovalDecision::Accept,
                    ApprovalDecisionValue::AcceptForSession => {
                        generated::FileChangeApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        generated::FileChangeApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => generated::FileChangeApprovalDecision::Cancel,
                },
            },
        ),
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            let requested_permissions = serde_json::from_str::<serde_json::Value>(&approval.raw_params_json)
                .ok()
                .and_then(|value| value.get("permissions").cloned())
                .and_then(|value| serde_json::from_value::<generated::GrantedPermissionProfile>(value).ok())
                .unwrap_or(generated::GrantedPermissionProfile {
                    network: None,
                    file_system: None,
                });
            serde_json::to_value(generated::PermissionsRequestApprovalResponse {
                permissions: match decision {
                    ApprovalDecisionValue::Accept | ApprovalDecisionValue::AcceptForSession => {
                        requested_permissions
                    }
                    ApprovalDecisionValue::Decline | ApprovalDecisionValue::Cancel => {
                        generated::GrantedPermissionProfile {
                            network: None,
                            file_system: None,
                        }
                    }
                },
                scope: match decision {
                    ApprovalDecisionValue::AcceptForSession => "session".to_string(),
                    _ => "once".to_string(),
                },
            })
        }
    }
    .map_err(|e| RpcError::Deserialization(format!("serialize approval response: {e}")))
}

#[cfg(test)]
mod mobile_client_tests {
    use super::*;

    #[test]
    fn reasoning_effort_parsing_accepts_known_values() {
        assert_eq!(
            reasoning_effort_from_string("low"),
            Some(generated::ReasoningEffort::Low)
        );
        assert_eq!(
            reasoning_effort_from_string("MEDIUM"),
            Some(generated::ReasoningEffort::Medium)
        );
        assert_eq!(
            reasoning_effort_from_string(" high "),
            Some(generated::ReasoningEffort::High)
        );
        assert_eq!(reasoning_effort_from_string(""), None);
    }
}
