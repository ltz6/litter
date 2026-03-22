//! Shared mobile client library for Codex iOS and Android apps.
//!
//! This crate provides a unified client interface that both platforms consume
//! through FFI, eliminating duplicated protocol types, transport logic,
//! session management, and business logic.

#[cfg(target_os = "ios")]
mod aec;

pub mod conversation;
/// FFI-exportable wrapper types for all Codex protocol messages.
pub mod types;

/// Transport layer: WebSocket, in-process channel, and JSON-RPC correlation.
pub mod transport;

/// Session management: connection lifecycle, thread management, event routing.
pub mod session;

/// Server discovery: Bonjour/mDNS, Tailscale, LAN probing.
pub mod discovery;

/// SSH bootstrap client for remote server setup.
pub mod ssh;

/// Tool call message parser (markdown → typed tool cards).
pub mod parser;

/// Progressive message hydration and LRU caching.
pub mod hydration;

/// FFI layer: UniFFI bindings for iOS and Android.
pub mod ffi;

// UniFFI scaffolding — must be in the crate root.
uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// MobileClient — top-level facade
// ---------------------------------------------------------------------------

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex, RwLock};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::hydration::{CacheKey, CachedMessage, MessageCache, MessageSegment};
use crate::parser::ToolCallCard;
use crate::session::connection::InProcessConfig;
use crate::session::connection::{ServerConfig, ServerSession};
use crate::session::events::{EventProcessor, UiEvent};
use crate::session::threads::{ThreadManager, ThreadState};
use crate::transport::{RpcError, TransportError};
use crate::types::{PendingApproval, ThreadInfo, ThreadKey};
use codex_app_server_protocol as upstream;

/// Top-level entry point for platform code (iOS / Android).
///
/// Ties together server sessions, thread management, event processing,
/// discovery, auth, caching, and voice handoff into a single facade.
/// All methods are safe to call from any thread (`Send + Sync`).
pub struct MobileClient {
    sessions: RwLock<HashMap<String, Arc<ServerSession>>>,
    thread_manager: RwLock<ThreadManager>,
    event_processor: Arc<EventProcessor>,
    discovery: RwLock<DiscoveryService>,
    cache: Mutex<MessageCache>,
}

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        Self {
            sessions: RwLock::new(HashMap::new()),
            thread_manager: RwLock::new(ThreadManager::new()),
            event_processor: Arc::new(EventProcessor::new()),
            discovery: RwLock::new(DiscoveryService::new(DiscoveryConfig::default())),
            cache: Mutex::new(MessageCache::new()),
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

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));

        self.sessions
            .write()
            .expect("sessions lock poisoned")
            .insert(server_id.clone(), session);

        info!("MobileClient: connected local server {server_id}");
        Ok(server_id)
    }

    /// Connect to a remote Codex server via WebSocket.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_remote(&self, config: ServerConfig) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        let session = Arc::new(ServerSession::connect_remote(config).await?);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));

        self.sessions
            .write()
            .expect("sessions lock poisoned")
            .insert(server_id.clone(), session);

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
            Self::spawn_detached(async move {
                session.disconnect().await;
            });
            info!("MobileClient: disconnected server {server_id}");
        } else {
            warn!("MobileClient: disconnect_server called for unknown {server_id}");
        }
    }

    /// Return the configs of all currently connected servers.
    pub fn connected_servers(&self) -> Vec<ServerConfig> {
        self.sessions
            .read()
            .expect("sessions lock poisoned")
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    // ── Threads ───────────────────────────────────────────────────────

    /// List threads from a specific server.
    pub async fn list_threads(&self, server_id: &str) -> Result<Vec<ThreadInfo>, RpcError> {
        let session = self.get_session(server_id)?;
        let tm = self
            .thread_manager
            .read()
            .expect("thread_manager lock poisoned");
        tm.list_threads(&session).await
    }

    /// Start a new thread on a server.
    pub async fn start_thread(
        &self,
        server_id: &str,
        params: upstream::ThreadStartParams,
    ) -> Result<ThreadKey, RpcError> {
        let session = self.get_session(server_id)?;
        let mut tm = self
            .thread_manager
            .write()
            .expect("thread_manager lock poisoned");
        tm.start_thread(&session, params).await
    }

    /// Resume an existing thread on a server.
    pub async fn resume_thread(
        &self,
        server_id: &str,
        thread_id: &str,
    ) -> Result<ThreadKey, RpcError> {
        let session = self.get_session(server_id)?;
        let mut tm = self
            .thread_manager
            .write()
            .expect("thread_manager lock poisoned");
        tm.resume_thread(&session, thread_id).await
    }

    /// Send a message / start a turn on a thread.
    pub async fn send_message(
        &self,
        key: &ThreadKey,
        params: upstream::TurnStartParams,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let mut tm = self
            .thread_manager
            .write()
            .expect("thread_manager lock poisoned");
        tm.send_message(&session, key, params).await
    }

    /// Interrupt the active turn on a thread.
    pub async fn interrupt_turn(&self, key: &ThreadKey) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let tm = self
            .thread_manager
            .read()
            .expect("thread_manager lock poisoned");
        tm.interrupt_turn(&session, key).await
    }

    /// Archive a thread.
    pub async fn archive_thread(&self, key: &ThreadKey) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let mut tm = self
            .thread_manager
            .write()
            .expect("thread_manager lock poisoned");
        tm.archive_thread(&session, key).await
    }

    /// Set the active thread. Pass `None` to clear.
    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.thread_manager
            .write()
            .expect("thread_manager lock poisoned")
            .set_active_thread(key);
    }

    /// Get the active thread state, if any.
    pub fn active_thread(&self) -> Option<ThreadState> {
        self.thread_manager
            .read()
            .expect("thread_manager lock poisoned")
            .active_thread()
            .cloned()
    }

    // ── Approvals ─────────────────────────────────────────────────────

    /// Approve a pending server request (tool call / file change / etc.).
    pub async fn approve(&self, request_id: &str) -> Result<(), RpcError> {
        let approval = self
            .event_processor
            .resolve_approval(request_id)
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no pending approval with id {request_id}"),
            })?;

        let server_id = approval
            .thread_id
            .as_ref()
            .and_then(|_| {
                // The approval doesn't carry server_id directly; find the session
                // that owns the thread. For now, iterate connected sessions.
                None::<String>
            })
            .or_else(|| {
                // Try to find the session from the thread manager.
                self.find_server_for_approval(&approval)
            })
            .unwrap_or_default();

        let session = self.get_session(&server_id)?;
        let result = serde_json::json!({ "approved": true });
        let id_value = serde_json::Value::String(approval.id);
        session.respond(id_value, result).await
    }

    /// Deny a pending server request.
    pub async fn deny(&self, request_id: &str) -> Result<(), RpcError> {
        let approval = self
            .event_processor
            .resolve_approval(request_id)
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no pending approval with id {request_id}"),
            })?;

        let server_id = self.find_server_for_approval(&approval).unwrap_or_default();
        let session = self.get_session(&server_id)?;
        let result = serde_json::json!({ "approved": false });
        let id_value = serde_json::Value::String(approval.id);
        session.respond(id_value, result).await
    }

    /// Return a snapshot of all pending approvals.
    pub fn pending_approvals(&self) -> Vec<PendingApproval> {
        self.event_processor.pending_approvals()
    }

    /// Access the event processor (for UniFFI wrapper subscription).
    pub fn event_processor(&self) -> &EventProcessor {
        &self.event_processor
    }

    // ── Events ────────────────────────────────────────────────────────

    /// Subscribe to the stream of high-level UI events.
    pub fn subscribe_ui_events(&self) -> broadcast::Receiver<UiEvent> {
        self.event_processor.subscribe()
    }

    // ── Discovery ─────────────────────────────────────────────────────

    /// Run a one-shot server discovery scan.
    pub async fn scan_servers(&self) -> Vec<DiscoveredServer> {
        // Clone the discovery ref without holding the lock across await.
        let discovery = { self.discovery.read().expect("discovery lock poisoned") };
        discovery.scan_once().await
    }

    /// Run a one-shot server discovery scan using platform-resolved mDNS seeds.
    pub async fn scan_servers_with_mdns(&self, seeds: Vec<MdnsSeed>) -> Vec<DiscoveredServer> {
        self.scan_servers_with_mdns_context(seeds, None).await
    }

    /// Run a one-shot server discovery scan using platform-resolved mDNS seeds
    /// plus optional network hints from the UI layer.
    pub async fn scan_servers_with_mdns_context(
        &self,
        seeds: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Vec<DiscoveredServer> {
        let discovery = { self.discovery.read().expect("discovery lock poisoned") };
        discovery
            .scan_once_with_context(&seeds, local_ipv4.as_deref())
            .await
    }

    // ── Cache / Parser ────────────────────────────────────────────────

    /// Parse tool call cards from a message text.
    pub fn parse_tool_calls(&self, text: &str) -> Vec<ToolCallCard> {
        crate::parser::parse_tool_call_message(text)
    }

    /// Cache a parsed message by key.
    pub fn cache_message(&self, key: CacheKey, text: &str) {
        let tool_calls = crate::parser::parse_tool_call_message(text);
        let segments = crate::hydration::extract_message_segments(text);
        let cached = CachedMessage {
            segments,
            tool_calls,
        };
        self.cache
            .lock()
            .expect("cache lock poisoned")
            .insert(key, cached);
    }

    /// Look up a cached message by key.
    /// Returns `None` if not cached. Promotes the entry in LRU order.
    pub fn get_cached(&self, key: &CacheKey) -> Option<CachedMessage> {
        self.cache
            .lock()
            .expect("cache lock poisoned")
            .get(key)
            .cloned()
    }

    /// Invalidate all cache entries for a given message id.
    pub fn invalidate_cache(&self, message_id: &str) {
        self.cache
            .lock()
            .expect("cache lock poisoned")
            .invalidate(message_id);
    }

    /// Clear the entire message cache.
    pub fn clear_cache(&self) {
        self.cache.lock().expect("cache lock poisoned").clear();
    }

    /// Extract message segments from text without caching.
    pub fn extract_segments(&self, text: &str) -> Vec<MessageSegment> {
        crate::hydration::extract_message_segments(text)
    }

    // ── Internal helpers ──────────────────────────────────────────────

    /// Look up a session by server_id, returning an `Arc` clone.
    fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions
            .read()
            .expect("sessions lock poisoned")
            .get(server_id)
            .cloned()
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no session for server_id '{server_id}'"),
            })
    }

    /// Spawn a background task that reads typed server events
    /// from a session and feeds them to the event processor.
    fn spawn_event_reader(&self, server_id: String, session: Arc<ServerSession>) {
        use crate::session::connection::ServerEvent;

        let event_processor = Arc::clone(&self.event_processor);

        let sid = server_id;
        let ep = event_processor;
        let mut event_rx = session.events();
        tokio::spawn(async move {
            loop {
                match event_rx.recv().await {
                    Ok(event) => match event {
                        ServerEvent::Notification(notification) => {
                            ep.process_notification(&sid, &notification);
                        }
                        ServerEvent::Request(request) => {
                            ep.process_server_request(&sid, &request);
                        }
                        ServerEvent::LegacyNotification { method, .. } => {
                            debug!(
                                "MobileClient: legacy notification for {sid}: {method} — ignored"
                            );
                        }
                    },
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!("MobileClient: event reader for {sid} lagged {n}");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        debug!("MobileClient: event channel closed for {sid}");
                        break;
                    }
                }
            }
        });
    }

    fn spawn_detached<F>(future: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(future);
            return;
        }

        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("failed to create Tokio runtime for detached task");
            runtime.block_on(future);
        });
    }

    /// Try to determine which server owns an approval based on thread keys.
    fn find_server_for_approval(&self, approval: &PendingApproval) -> Option<String> {
        let thread_id = approval.thread_id.as_ref()?;
        let sessions = self.sessions.read().expect("sessions lock poisoned");
        // Try each connected server — the one whose thread manager knows this thread.
        let tm = self
            .thread_manager
            .read()
            .expect("thread_manager lock poisoned");
        for (server_id, _session) in sessions.iter() {
            let key = ThreadKey {
                server_id: server_id.clone(),
                thread_id: thread_id.clone(),
            };
            if tm.thread(&key).is_some() {
                return Some(server_id.clone());
            }
        }
        // Fallback: if only one session is connected, use it.
        if sessions.len() == 1 {
            return sessions.keys().next().cloned();
        }
        None
    }

    /// Send a typed `ClientRequest` to a specific server session and deserialize the response.
    pub async fn request_typed_for_server<R: serde::de::DeserializeOwned>(
        &self,
        server_id: &str,
        request: codex_app_server_protocol::ClientRequest,
    ) -> Result<R, String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        let result = session
            .request_client(request)
            .await
            .map_err(|e| e.to_string())?;
        #[cfg(feature = "rpc-trace")]
        {
            let dst = std::any::type_name::<R>();
            eprintln!("[codex-rpc] response -> {dst}");
        }
        serde_json::from_value(result.clone()).map_err(|e| {
            #[cfg(feature = "rpc-trace")]
            {
                let dst = std::any::type_name::<R>();
                let json = serde_json::to_string_pretty(&result).unwrap_or_default();
                eprintln!(
                    "[codex-rpc] FAILED response -> {dst}: {e}\n--- response JSON ---\n{json}\n---"
                );
            }
            format!("deserialize response: {e}")
        })
    }

    /// Send a response to a server request on a specific server.
    pub async fn respond_for_server(
        &self,
        server_id: &str,
        id: serde_json::Value,
        result: serde_json::Value,
    ) -> Result<(), String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session.respond(id, result).await.map_err(|e| e.to_string())
    }

    /// Reject a server request on a specific server with a JSON-RPC error.
    pub async fn reject_for_server(
        &self,
        server_id: &str,
        id: serde_json::Value,
        error: codex_app_server_protocol::JSONRPCErrorError,
    ) -> Result<(), String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session.reject(id, error).await.map_err(|e| e.to_string())
    }

}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod mobile_client_tests {
    use super::*;

    fn make_client() -> MobileClient {
        MobileClient::new()
    }

    // -- Construction --

    #[test]
    fn new_client_has_no_sessions() {
        let client = make_client();
        assert!(client.connected_servers().is_empty());
    }

    #[test]
    fn new_client_has_no_active_thread() {
        let client = make_client();
        assert!(client.active_thread().is_none());
    }

    #[test]
    fn new_client_has_no_pending_approvals() {
        let client = make_client();
        assert!(client.pending_approvals().is_empty());
    }

    // -- Send + Sync --

    #[test]
    fn mobile_client_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<MobileClient>();
    }

    // -- Active thread --

    #[test]
    fn set_and_get_active_thread() {
        let client = make_client();
        let key = ThreadKey {
            server_id: "srv1".into(),
            thread_id: "thr_1".into(),
        };
        client.set_active_thread(Some(key.clone()));
        // active_thread() returns None because the ThreadManager doesn't
        // have a ThreadState for this key (it was never started/resumed).
        assert!(client.active_thread().is_none());
    }

    #[test]
    fn clear_active_thread() {
        let client = make_client();
        client.set_active_thread(None);
        assert!(client.active_thread().is_none());
    }

    // -- Parser --

    #[test]
    fn parse_tool_calls_empty_text() {
        let client = make_client();
        let cards = client.parse_tool_calls("");
        assert!(cards.is_empty());
    }

    #[test]
    fn parse_tool_calls_with_tool_header() {
        let client = make_client();
        let text = "### 🔧 Command Execution\n**Command:** `ls -la`\n```\nfoo bar\n```\n";
        let cards = client.parse_tool_calls(text);
        // Should parse at least one card.
        assert!(!cards.is_empty());
    }

    // -- Cache --

    #[test]
    fn cache_message_and_verify() {
        let client = make_client();
        let key = CacheKey {
            message_id: "msg1".into(),
            revision_token: "r1".into(),
            server_id: "srv1".into(),
            agent_directory_version: 0,
        };
        client.cache_message(key.clone(), "Hello world");

        let mut cache = client.cache.lock().unwrap();
        let cached = cache.get(&key);
        assert!(cached.is_some());
    }

    // -- Subscribe --

    #[test]
    fn subscribe_ui_events_returns_receiver() {
        let client = make_client();
        let _rx = client.subscribe_ui_events();
    }

    // -- Disconnect unknown server --

    #[test]
    fn disconnect_unknown_server_does_not_panic() {
        let client = make_client();
        client.disconnect_server("nonexistent");
    }

    // -- get_session errors --

    #[test]
    fn get_session_unknown_returns_error() {
        let client = make_client();
        let result = client.get_session("unknown");
        assert!(result.is_err());
    }

    // -- Integration with remote server --

    #[tokio::test]
    async fn connect_and_disconnect_remote() {
        use futures::{SinkExt, StreamExt};
        use tokio::net::TcpListener;
        use tokio_tungstenite::accept_async;
        use tokio_tungstenite::tungstenite::protocol::Message;

        // Start a WS server that handles the initialize/initialized handshake.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let server = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let ws = match accept_async(stream).await {
                    Ok(ws) => ws,
                    Err(_) => continue,
                };
                let (mut sink, mut stream) = ws.split();
                while let Some(Ok(msg)) = stream.next().await {
                    match msg {
                        Message::Text(text) => {
                            // Handle JSON-RPC messages
                            if let Ok(parsed) =
                                serde_json::from_str::<serde_json::Value>(text.as_ref())
                            {
                                if let Some(id) = parsed.get("id") {
                                    if parsed.get("method").is_some() {
                                        // Request — respond with success
                                        let response = serde_json::json!({
                                            "id": id,
                                            "result": {}
                                        });
                                        let _ = sink
                                            .send(Message::Text(response.to_string().into()))
                                            .await;
                                    }
                                }
                                // Notifications (like "initialized") — just consume
                            }
                        }
                        Message::Ping(data) => {
                            let _ = sink.send(Message::Pong(data)).await;
                        }
                        Message::Close(_) => break,
                        _ => {}
                    }
                }
            }
        });

        let client = make_client();
        let config = ServerConfig {
            server_id: "test-1".into(),
            display_name: "Test".into(),
            host: "127.0.0.1".into(),
            port: addr.port(),
            is_local: false,
            tls: false,
        };

        let sid = client.connect_remote(config).await.expect("should connect");
        assert_eq!(sid, "test-1");
        assert_eq!(client.connected_servers().len(), 1);

        client.disconnect_server("test-1");
        // Give the async disconnect a moment.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(client.connected_servers().is_empty());

        server.abort();
    }

    #[tokio::test]
    async fn connect_remote_invalid_port_fails() {
        let client = make_client();
        let config = ServerConfig {
            server_id: "bad".into(),
            display_name: "Bad".into(),
            host: "127.0.0.1".into(),
            port: 1,
            is_local: false,
            tls: false,
        };

        let result = client.connect_remote(config).await;
        assert!(result.is_err());
        assert!(client.connected_servers().is_empty());
    }

    #[tokio::test]
    async fn list_threads_unknown_server_returns_error() {
        let client = make_client();
        let result = client.list_threads("nonexistent").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn approve_unknown_id_returns_error() {
        let client = make_client();
        let result = client.approve("999").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn deny_unknown_id_returns_error() {
        let client = make_client();
        let result = client.deny("999").await;
        assert!(result.is_err());
    }

    // -- Discovery (scan_once with no network returns empty) --

    #[tokio::test]
    async fn scan_servers_returns_vec() {
        let client = make_client();
        let servers = client.scan_servers().await;
        // With default config and no real network, may return empty.
        // Just verify it doesn't panic and returns a Vec.
        let _ = servers;
    }
}
