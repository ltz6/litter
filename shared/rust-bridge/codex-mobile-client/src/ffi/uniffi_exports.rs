//! UniFFI-exported async wrapper around `MobileClient`.
//!
//! Uses `spawn_blocking` to run MobileClient's !Send futures on a
//! blocking thread pool, then awaits the result. This makes the
//! exported futures Send-safe for UniFFI async export.

use crate::MobileClient;
use crate::discovery::{DiscoverySource, MdnsSeed};
use crate::hydration::FfiMessageSegment;
use crate::parser::FfiToolCallCard;
use crate::session::connection::{InProcessConfig, ServerConfig};
use crate::session::events::UiEvent;
use crate::ssh::{ExecResult, SshAuth, SshBootstrapResult, SshClient, SshCredentials, SshError};
use crate::types::generated;
use crate::types::models::{ThreadInfo, ThreadKey};
use codex_app_server_protocol as upstream;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

static REQUEST_COUNTER: AtomicI64 = AtomicI64::new(1);
pub(crate) fn next_id() -> i64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

fn convert_generated_thread_item(item: generated::ThreadItem) -> Result<upstream::ThreadItem, ClientError> {
    super::generated_rpc::convert_generated_field(item)
}

#[derive(uniffi::Object)]
pub struct CodexClient {
    inner: Arc<MobileClient>,
    rt: Arc<tokio::runtime::Runtime>,
    event_rx: std::sync::Mutex<Option<tokio::sync::broadcast::Receiver<UiEvent>>>,
    ssh_sessions: std::sync::Mutex<HashMap<String, ManagedSshSession>>,
    next_ssh_session_id: AtomicU64,
}

#[derive(uniffi::Object)]
pub struct EventSubscription {
    rx: std::sync::Mutex<Option<tokio::sync::broadcast::Receiver<UiEvent>>>,
}

#[derive(Clone)]
struct ManagedSshSession {
    client: Arc<SshClient>,
    server_port: Option<u16>,
    tunnel_local_port: Option<u16>,
    pid: Option<u32>,
}

/// Helper: run a !Send async closure on a blocking thread via spawn_blocking + block_on.
macro_rules! blocking_async {
    ($rt:expr, $inner:expr, |$client:ident| $body:expr) => {{
        let rt = Arc::clone(&$rt);
        let inner = Arc::clone(&$inner);
        tokio::task::spawn_blocking(move || {
            let $client = &inner;
            rt.block_on(async { $body })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?
    }};
}

#[uniffi::export(async_runtime = "tokio")]
impl CodexClient {
    #[uniffi::constructor]
    pub fn new() -> Self {
        let rt = Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("failed to create tokio runtime"),
        );
        let inner = Arc::new(MobileClient::new());
        let rx = inner.event_processor().subscribe();
        Self {
            inner,
            rt,
            event_rx: std::sync::Mutex::new(Some(rx)),
            ssh_sessions: std::sync::Mutex::new(HashMap::new()),
            next_ssh_session_id: AtomicU64::new(1),
        }
    }

    pub async fn connect_local(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    ) -> Result<String, ClientError> {
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            is_local: true,
            tls: false,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_local(config, InProcessConfig::default())
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    ) -> Result<String, ClientError> {
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            is_local: false,
            tls: false,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote(config)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub fn disconnect_server(&self, server_id: String) {
        self.inner.disconnect_server(&server_id);
    }

    pub async fn scan_servers_with_mdns_seeds(
        &self,
        seeds: Vec<FfiMdnsSeed>,
    ) -> Result<Vec<FfiDiscoveredServer>, ClientError> {
        self.scan_servers_with_mdns_context(seeds, None).await
    }

    pub async fn scan_servers_with_mdns_context(
        &self,
        seeds: Vec<FfiMdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Result<Vec<FfiDiscoveredServer>, ClientError> {
        let seeds: Vec<MdnsSeed> = seeds.into_iter().map(MdnsSeed::from).collect();
        blocking_async!(self.rt, self.inner, |c| {
            Ok(c.scan_servers_with_mdns_context(seeds, local_ipv4)
                .await
                .into_iter()
                .map(FfiDiscoveredServer::from)
                .collect())
        })
    }

    pub async fn list_threads(&self, server_id: String) -> Result<Vec<ThreadInfo>, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.list_threads(&server_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    /// Parse tool calls from text. Sync — no async needed.
    pub fn parse_tool_calls(&self, text: String) -> Result<String, ClientError> {
        let cards = self.inner.parse_tool_calls(&text);
        serde_json::to_string(&cards).map_err(|e| ClientError::Serialization(e.to_string()))
    }

    pub fn parse_tool_calls_typed(&self, text: String) -> Vec<FfiToolCallCard> {
        self.inner
            .parse_tool_calls(&text)
            .iter()
            .map(FfiToolCallCard::from)
            .collect()
    }

    pub fn extract_segments_typed(&self, text: String) -> Vec<FfiMessageSegment> {
        self.inner
            .extract_segments(&text)
            .into_iter()
            .map(FfiMessageSegment::from)
            .collect()
    }

    pub fn hydrate_turns(&self, turns_json: String) -> Result<String, ClientError> {
        use crate::conversation::{HydrationOptions, hydrate_turns};
        use codex_app_server_protocol::Turn;
        let turns: Vec<Turn> = serde_json::from_str(&turns_json)
            .map_err(|e| ClientError::InvalidParams(format!("invalid turns JSON: {e}")))?;
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        serde_json::to_string(&items).map_err(|e| ClientError::Serialization(e.to_string()))
    }

    pub fn hydrate_thread_item(
        &self,
        item: generated::ThreadItem,
        turn_id: Option<String>,
        default_agent_nickname: Option<String>,
        default_agent_role: Option<String>,
    ) -> Result<Option<HydratedConversationItem>, ClientError> {
        use crate::conversation::{HydrationOptions, hydrate_thread_item};

        let upstream_item = convert_generated_thread_item(item)?;
        let opts = HydrationOptions {
            default_agent_nickname,
            default_agent_role,
        };
        Ok(hydrate_thread_item(&upstream_item, turn_id.as_deref(), None, &opts).map(Into::into))
    }

    /// Typed event polling — returns the next UiEvent directly, no JSON.
    pub async fn next_event(&self) -> Result<UiEvent, ClientError> {
        self.next_event_internal().await
    }

    pub fn subscribe_events(&self) -> Arc<EventSubscription> {
        Arc::new(EventSubscription {
            rx: std::sync::Mutex::new(Some(self.inner.event_processor().subscribe())),
        })
    }

    // ── SSH methods ─────────────────────────────────────────────────────

    pub async fn ssh_connect(
        &self,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        accept_unknown_host: bool,
    ) -> Result<String, ClientError> {
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        let normalized_host = normalize_ssh_host(&host);

        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
        };

        let rt = Arc::clone(&self.rt);
        let session = tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                SshClient::connect(
                    credentials,
                    Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
                )
                .await
                .map_err(map_ssh_error)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))??;

        let session_id = format!(
            "ssh-{}",
            self.next_ssh_session_id.fetch_add(1, Ordering::Relaxed)
        );
        self.ssh_sessions
            .lock()
            .expect("ssh_sessions lock poisoned")
            .insert(
                session_id.clone(),
                ManagedSshSession {
                    client: Arc::new(session),
                    server_port: None,
                    tunnel_local_port: None,
                    pid: None,
                },
            );
        Ok(session_id)
    }

    pub async fn ssh_connect_and_bootstrap(
        &self,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        accept_unknown_host: bool,
        working_dir: Option<String>,
    ) -> Result<FfiSshConnectionResult, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
        };

        let rt = Arc::clone(&self.rt);
        let session = tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                SshClient::connect(
                    credentials,
                    Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
                )
                .await
                .map_err(map_ssh_error)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))??;

        let session = Arc::new(session);
        let bootstrap = {
            let session = Arc::clone(&session);
            let rt = Arc::clone(&self.rt);
            let working_dir = working_dir.clone();
            let use_ipv6 = normalized_host.contains(':');
            tokio::task::spawn_blocking(move || {
                rt.block_on(async move {
                    session
                        .bootstrap_codex_server(working_dir.as_deref(), use_ipv6)
                        .await
                        .map_err(map_ssh_error)
                })
            })
            .await
            .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?
        };

        let bootstrap = match bootstrap {
            Ok(result) => result,
            Err(error) => {
                let session = Arc::clone(&session);
                let rt = Arc::clone(&self.rt);
                let _ = tokio::task::spawn_blocking(move || {
                    rt.block_on(async move {
                        session.disconnect().await;
                    })
                })
                .await;
                return Err(error);
            }
        };

        let wake_mac = self.ssh_read_wake_mac(Arc::clone(&session)).await;
        let session_id = format!(
            "ssh-{}",
            self.next_ssh_session_id.fetch_add(1, Ordering::Relaxed)
        );
        self.ssh_sessions
            .lock()
            .expect("ssh_sessions lock poisoned")
            .insert(
                session_id.clone(),
                ManagedSshSession {
                    client: Arc::clone(&session),
                    server_port: Some(bootstrap.server_port),
                    tunnel_local_port: Some(bootstrap.tunnel_local_port),
                    pid: bootstrap.pid,
                },
            );

        Ok(FfiSshConnectionResult {
            session_id,
            normalized_host,
            server_port: bootstrap.server_port,
            tunnel_local_port: Some(bootstrap.tunnel_local_port),
            server_version: bootstrap.server_version,
            pid: bootstrap.pid,
            wake_mac,
        })
    }

    pub async fn ssh_bootstrap(
        &self,
        session_id: String,
        working_dir: Option<String>,
        ipv6: bool,
    ) -> Result<FfiSshBootstrapResult, ClientError> {
        let session = self.ssh_session(&session_id)?;
        let rt = Arc::clone(&self.rt);
        let result = tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                session
                    .bootstrap_codex_server(working_dir.as_deref(), ipv6)
                    .await
                    .map(FfiSshBootstrapResult::from)
                    .map_err(map_ssh_error)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?;
        if let Ok(ref bootstrap) = result {
            let mut sessions = self.ssh_sessions.lock().expect("ssh_sessions lock poisoned");
            if let Some(entry) = sessions.get_mut(&session_id) {
                entry.server_port = Some(bootstrap.server_port);
                entry.tunnel_local_port = Some(bootstrap.tunnel_local_port);
                entry.pid = bootstrap.pid;
            }
        }
        result
    }

    pub async fn ssh_exec(
        &self,
        session_id: String,
        command: String,
    ) -> Result<FfiSshExecResult, ClientError> {
        let session = self.ssh_session(&session_id)?;
        let rt = Arc::clone(&self.rt);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                session
                    .exec(&command)
                    .await
                    .map(FfiSshExecResult::from)
                    .map_err(map_ssh_error)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?
    }

    pub async fn ssh_disconnect(&self, session_id: String) -> Result<(), ClientError> {
        let session = self
            .ssh_sessions
            .lock()
            .expect("ssh_sessions lock poisoned")
            .remove(&session_id)
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })?;
        let rt = Arc::clone(&self.rt);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                session.client.disconnect().await;
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?;
        Ok(())
    }

    pub async fn ssh_close(&self, session_id: String) -> Result<(), ClientError> {
        let session = self
            .ssh_sessions
            .lock()
            .expect("ssh_sessions lock poisoned")
            .remove(&session_id)
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })?;
        let rt = Arc::clone(&self.rt);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                if let Some(pid) = session.pid {
                    let _ = session.client.exec(&format!("kill {pid} 2>/dev/null")).await;
                }
                session.client.disconnect().await;
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?;
        Ok(())
    }

    // ── Typed RPC methods ──────────────────────────────────────────────
    //
    // Each method takes flat typed arguments, constructs JSON params,
    // routes to the correct server session via server_id, and returns
    // a fully typed response struct.

    pub async fn rpc_thread_list(
        &self,
        server_id: String,
        cursor: Option<String>,
        limit: Option<u32>,
        sort_key: Option<String>,
        cwd: Option<String>,
    ) -> Result<generated::ThreadListResponse, ClientError> {
        let sort_key = sort_key
            .and_then(|value| serde_json::from_value(serde_json::Value::String(value)).ok());
        self.generated_thread_list(
            &server_id,
            generated::ThreadListParams {
                cursor,
                limit,
                sort_key,
                model_providers: None,
                source_kinds: None,
                archived: None,
                cwd,
                search_term: None,
            },
        )
        .await
    }

    pub async fn rpc_thread_start(
        &self,
        server_id: String,
        model: Option<String>,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
        dynamic_tools: Option<Vec<generated::DynamicToolSpec>>,
        persist_extended_history: bool,
    ) -> Result<ThreadKey, ClientError> {
        use codex_app_server_protocol as upstream;

        let sandbox_mode = sandbox
            .map(super::generated_rpc::convert_generated_field)
            .transpose()?;
        let approval_policy = approval_policy
            .map(super::generated_rpc::convert_generated_field)
            .transpose()?;

        let tools = dynamic_tools
            .map(|tools| {
                tools
                    .into_iter()
                    .map(super::generated_rpc::convert_generated_field)
                    .collect::<Result<Vec<upstream::DynamicToolSpec>, ClientError>>()
            })
            .transpose()?;

        let params = upstream::ThreadStartParams {
            model,
            approval_policy,
            cwd,
            sandbox: sandbox_mode,
            developer_instructions,
            dynamic_tools: tools,
            persist_extended_history,
            ..Default::default()
        };

        blocking_async!(self.rt, self.inner, |c| {
            c.start_thread(&server_id, params)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn rpc_thread_read(
        &self,
        server_id: String,
        thread_id: String,
        include_turns: bool,
    ) -> Result<generated::ThreadReadResponse, ClientError> {
        self.generated_thread_read(
            &server_id,
            Self::thread_read_params(thread_id, include_turns),
        )
        .await
    }

    /// Read a thread and hydrate its turns in one call.
    /// Returns the typed response + hydrated conversation items as JSON.
    pub async fn rpc_thread_read_hydrated(
        &self,
        server_id: String,
        thread_id: String,
    ) -> Result<ThreadResponseWithHydration, ClientError> {
        let response = self
            .generated_thread_read(&server_id, Self::thread_read_params(thread_id, true))
            .await?;
        self.hydrate_serializable_response(&response)
    }

    /// Resume a thread and hydrate its turns in one call.
    pub async fn rpc_thread_resume_hydrated(
        &self,
        server_id: String,
        thread_id: String,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
    ) -> Result<ThreadResponseWithHydration, ClientError> {
        let response = self
            .generated_thread_resume(
                &server_id,
                Self::thread_resume_params(
                    thread_id,
                    cwd,
                    approval_policy,
                    sandbox,
                    developer_instructions,
                )?,
            )
            .await?;
        self.hydrate_serializable_response(&response)
    }

    /// Fork a thread and hydrate its turns in one call.
    pub async fn rpc_thread_fork_hydrated(
        &self,
        server_id: String,
        thread_id: String,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
    ) -> Result<ThreadResponseWithHydration, ClientError> {
        let response = self
            .generated_thread_fork(
                &server_id,
                Self::thread_fork_params(
                    thread_id,
                    cwd,
                    approval_policy,
                    sandbox,
                    developer_instructions,
                )?,
            )
            .await?;
        self.hydrate_serializable_response(&response)
    }

    /// Rollback a thread and hydrate its turns in one call.
    pub async fn rpc_thread_rollback_hydrated(
        &self,
        server_id: String,
        thread_id: String,
        num_turns: u32,
    ) -> Result<ThreadResponseWithHydration, ClientError> {
        let response = self
            .generated_thread_rollback(&server_id, Self::thread_rollback_params(thread_id, num_turns))
            .await?;
        self.hydrate_serializable_response(&response)
    }

    pub async fn rpc_thread_resume(
        &self,
        server_id: String,
        thread_id: String,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
    ) -> Result<generated::ThreadResumeResponse, ClientError> {
        self.generated_thread_resume(
            &server_id,
            Self::thread_resume_params(
                thread_id,
                cwd,
                approval_policy,
                sandbox,
                developer_instructions,
            )?,
        )
        .await
    }

    pub async fn rpc_thread_fork(
        &self,
        server_id: String,
        thread_id: String,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
    ) -> Result<generated::ThreadForkResponse, ClientError> {
        self.generated_thread_fork(
            &server_id,
            Self::thread_fork_params(
                thread_id,
                cwd,
                approval_policy,
                sandbox,
                developer_instructions,
            )?,
        )
        .await
    }

    pub async fn rpc_turn_start(
        &self,
        server_id: String,
        thread_id: String,
        input: Vec<generated::UserInput>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox_policy_json: Option<String>,
        model: Option<String>,
        effort: Option<generated::ReasoningEffort>,
        service_tier: Option<generated::ServiceTier>,
    ) -> Result<(), ClientError> {
        let sandbox_policy = match sandbox_policy_json {
            Some(json) => Some(serde_json::from_str(&json).map_err(|e| {
                ClientError::InvalidParams(format!("invalid sandbox policy JSON: {e}"))
            })?),
            None => None,
        };
        let generated_params = generated::TurnStartParams {
            thread_id: thread_id.clone(),
            input,
            cwd: None,
            approval_policy,
            approvals_reviewer: None,
            sandbox_policy,
            model,
            service_tier: service_tier.map(Some),
            effort,
            summary: None,
            personality: None,
            output_schema: None,
            collaboration_mode: None,
        };
        let params: upstream::TurnStartParams =
            super::generated_rpc::convert_generated_field(generated_params)?;

        let key = ThreadKey {
            server_id,
            thread_id,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.send_message(&key, params)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn rpc_turn_interrupt(
        &self,
        server_id: String,
        thread_id: String,
        turn_id: String,
    ) -> Result<(), ClientError> {
        let _: generated::TurnInterruptResponse = self
            .generated_turn_interrupt(
                &server_id,
                generated::TurnInterruptParams { thread_id, turn_id },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_thread_rollback(
        &self,
        server_id: String,
        thread_id: String,
        num_turns: u32,
    ) -> Result<generated::ThreadRollbackResponse, ClientError> {
        self.generated_thread_rollback(
            &server_id,
            Self::thread_rollback_params(thread_id, num_turns),
        )
        .await
    }

    pub async fn rpc_thread_archive(
        &self,
        server_id: String,
        thread_id: String,
    ) -> Result<(), ClientError> {
        let key = ThreadKey {
            server_id,
            thread_id,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.archive_thread(&key)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn approve(&self, request_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.approve(&request_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn deny(&self, request_id: String) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.deny(&request_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn rpc_thread_set_name(
        &self,
        server_id: String,
        thread_id: String,
        name: String,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadSetNameResponse = self
            .generated_thread_set_name(
                &server_id,
                generated::ThreadSetNameParams { thread_id, name },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_model_list(
        &self,
        server_id: String,
        limit: Option<u32>,
        include_hidden: bool,
    ) -> Result<generated::ModelListResponse, ClientError> {
        self.generated_model_list(
            &server_id,
            generated::ModelListParams {
                cursor: None,
                limit,
                include_hidden: Some(include_hidden),
            },
        )
        .await
    }

    pub async fn rpc_command_exec(
        &self,
        server_id: String,
        command: Vec<String>,
        cwd: Option<String>,
    ) -> Result<generated::CommandExecResponse, ClientError> {
        let req = upstream::ClientRequest::OneOffCommandExec {
            request_id: upstream::RequestId::Integer(next_id()),
            params: upstream::CommandExecParams {
                command,
                process_id: None,
                tty: false,
                stream_stdin: false,
                stream_stdout_stderr: false,
                output_bytes_cap: None,
                disable_output_cap: false,
                disable_timeout: false,
                timeout_ms: None,
                cwd: cwd.map(Into::into),
                env: None,
                size: None,
                sandbox_policy: None,
            },
        };
        self.request_typed(&server_id, req).await
    }

    pub async fn rpc_fuzzy_file_search(
        &self,
        server_id: String,
        query: String,
        roots: Vec<String>,
        cancellation_token: Option<String>,
    ) -> Result<generated::FuzzyFileSearchResponse, ClientError> {
        let req = upstream::ClientRequest::FuzzyFileSearch {
            request_id: upstream::RequestId::Integer(next_id()),
            params: upstream::FuzzyFileSearchParams {
                query,
                roots,
                cancellation_token,
            },
        };
        self.request_typed(&server_id, req).await
    }

    pub async fn rpc_skills_list(
        &self,
        server_id: String,
        cwds: Option<Vec<String>>,
        force_reload: bool,
    ) -> Result<generated::SkillsListResponse, ClientError> {
        self.generated_skills_list(
            &server_id,
            generated::SkillsListParams {
                cwds: cwds
                    .unwrap_or_default()
                    .into_iter()
                    .map(|value| generated::AbsolutePath { value })
                    .collect(),
                force_reload,
                per_cwd_extra_user_roots: None,
            },
        )
        .await
    }

    pub async fn rpc_experimental_feature_list(
        &self,
        server_id: String,
        cursor: Option<String>,
        limit: Option<u32>,
    ) -> Result<generated::ExperimentalFeatureListResponse, ClientError> {
        self.generated_experimental_feature_list(
            &server_id,
            generated::ExperimentalFeatureListParams { cursor, limit },
        )
        .await
    }

    pub async fn rpc_config_read(
        &self,
        server_id: String,
        cwd: Option<String>,
    ) -> Result<generated::ConfigReadResponse, ClientError> {
        self.generated_config_read(
            &server_id,
            generated::ConfigReadParams {
                include_layers: false,
                cwd,
            },
        )
        .await
    }

    pub async fn rpc_config_value_write(
        &self,
        server_id: String,
        key_path: String,
        value: generated::JsonValue,
        merge_strategy: generated::MergeStrategy,
    ) -> Result<generated::ConfigWriteResponse, ClientError> {
        self.generated_config_value_write(
            &server_id,
            generated::ConfigValueWriteParams {
                key_path,
                value,
                merge_strategy,
                file_path: None,
                expected_version: None,
            },
        )
        .await
    }

    pub async fn rpc_config_batch_write(
        &self,
        server_id: String,
        edits: Vec<generated::ConfigEdit>,
        reload_user_config: bool,
    ) -> Result<generated::ConfigWriteResponse, ClientError> {
        self.generated_config_batch_write(
            &server_id,
            generated::ConfigBatchWriteParams {
                edits,
                file_path: None,
                expected_version: None,
                reload_user_config,
            },
        )
        .await
    }

    pub async fn rpc_review_start(
        &self,
        server_id: String,
        thread_id: String,
    ) -> Result<generated::ReviewStartResponse, ClientError> {
        self.generated_review_start(
            &server_id,
            generated::ReviewStartParams {
                thread_id,
                target: generated::ReviewTarget::UncommittedChanges,
                delivery: Some("inline".to_string()),
            },
        )
        .await
    }

    // ── Auth methods ────────────────────────────────────────────────────

    pub async fn rpc_account_read(
        &self,
        server_id: String,
        refresh_token: bool,
    ) -> Result<generated::GetAccountResponse, ClientError> {
        self.generated_get_account(&server_id, generated::GetAccountParams { refresh_token })
            .await
    }

    pub async fn rpc_get_auth_status(
        &self,
        server_id: String,
        include_token: bool,
        refresh_token: bool,
    ) -> Result<generated::GetAuthStatusResponse, ClientError> {
        let req = upstream::ClientRequest::GetAuthStatus {
            request_id: upstream::RequestId::Integer(next_id()),
            params: upstream::GetAuthStatusParams {
                include_token: Some(include_token),
                refresh_token: Some(refresh_token),
            },
        };
        self.request_typed(&server_id, req).await
    }

    pub async fn rpc_login_start_chatgpt(
        &self,
        server_id: String,
    ) -> Result<generated::LoginAccountResponse, ClientError> {
        self.generated_login_account(&server_id, generated::LoginAccountParams::Chatgpt)
            .await
    }

    pub async fn rpc_login_start_api_key(
        &self,
        server_id: String,
        api_key: String,
    ) -> Result<generated::LoginAccountResponse, ClientError> {
        self.generated_login_account(
            &server_id,
            generated::LoginAccountParams::ApiKey { api_key },
        )
        .await
    }

    pub async fn rpc_login_start_chatgpt_auth_tokens(
        &self,
        server_id: String,
        access_token: String,
        chatgpt_account_id: String,
        chatgpt_plan_type: Option<String>,
    ) -> Result<generated::LoginAccountResponse, ClientError> {
        self.generated_login_account(
            &server_id,
            generated::LoginAccountParams::ChatgptAuthTokens {
                access_token,
                chatgpt_account_id,
                chatgpt_plan_type,
            },
        )
        .await
    }

    pub async fn rpc_account_logout(&self, server_id: String) -> Result<(), ClientError> {
        let _: generated::LogoutAccountResponse = self.generated_logout_account(&server_id).await?;
        Ok(())
    }

    pub async fn rpc_account_login_cancel(
        &self,
        server_id: String,
        login_id: String,
    ) -> Result<(), ClientError> {
        let _: generated::CancelLoginAccountResponse = self
            .generated_cancel_login_account(
                &server_id,
                generated::CancelLoginAccountParams { login_id },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_account_rate_limits_read(
        &self,
        server_id: String,
    ) -> Result<generated::GetAccountRateLimitsResponse, ClientError> {
        self.generated_get_account_rate_limits(&server_id).await
    }

    // ── Realtime voice methods ──────────────────────────────────────────

    pub async fn rpc_realtime_start(
        &self,
        server_id: String,
        thread_id: String,
        prompt: String,
        session_id: Option<String>,
        client_controlled_handoff: bool,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadRealtimeStartResponse = self
            .generated_thread_realtime_start(
                &server_id,
                generated::ThreadRealtimeStartParams {
                    thread_id,
                    prompt,
                    session_id,
                    client_controlled_handoff,
                },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_realtime_append_audio(
        &self,
        server_id: String,
        thread_id: String,
        audio_data: String,
        sample_rate: u32,
        num_channels: u32,
        samples_per_channel: Option<u32>,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadRealtimeAppendAudioResponse = self
            .generated_thread_realtime_append_audio(
                &server_id,
                generated::ThreadRealtimeAppendAudioParams {
                    thread_id,
                    audio: generated::ThreadRealtimeAudioChunk {
                        data: audio_data,
                        sample_rate,
                        num_channels,
                        samples_per_channel,
                    },
                },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_realtime_append_text(
        &self,
        server_id: String,
        thread_id: String,
        text: String,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadRealtimeAppendTextResponse = self
            .generated_thread_realtime_append_text(
                &server_id,
                generated::ThreadRealtimeAppendTextParams { thread_id, text },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_realtime_stop(
        &self,
        server_id: String,
        thread_id: String,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadRealtimeStopResponse = self
            .generated_thread_realtime_stop(
                &server_id,
                generated::ThreadRealtimeStopParams { thread_id },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_realtime_resolve_handoff(
        &self,
        server_id: String,
        thread_id: String,
        handoff_id: String,
        output_text: String,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadRealtimeResolveHandoffResponse = self
            .generated_thread_realtime_resolve_handoff(
                &server_id,
                generated::ThreadRealtimeResolveHandoffParams {
                    thread_id,
                    handoff_id,
                    output_text,
                },
            )
            .await?;
        Ok(())
    }

    pub async fn rpc_realtime_finalize_handoff(
        &self,
        server_id: String,
        thread_id: String,
        handoff_id: String,
    ) -> Result<(), ClientError> {
        let _: generated::ThreadRealtimeFinalizeHandoffResponse = self
            .generated_thread_realtime_finalize_handoff(
                &server_id,
                generated::ThreadRealtimeFinalizeHandoffParams {
                    thread_id,
                    handoff_id,
                },
            )
            .await?;
        Ok(())
    }

    /// Generic respond (for cases not covered by typed methods).
    pub async fn rpc_respond(
        &self,
        server_id: String,
        request_id: String,
        result_json: String,
    ) -> Result<(), ClientError> {
        let result: serde_json::Value = serde_json::from_str(&result_json)
            .map_err(|e| ClientError::InvalidParams(e.to_string()))?;
        self.respond_internal(&server_id, &request_id, result).await
    }

    /// Generic error response for server-initiated requests.
    pub async fn rpc_respond_error(
        &self,
        server_id: String,
        request_id: String,
        code: i32,
        message: String,
    ) -> Result<(), ClientError> {
        let error = upstream::JSONRPCErrorError {
            code: i64::from(code),
            message,
            data: None,
        };
        self.reject_internal(&server_id, &request_id, error).await
    }
}

#[cfg(test)]
mod tests {
    use super::convert_generated_thread_item;
    use crate::types::generated;
    use codex_app_server_protocol as upstream;
    use serde_json::json;

    #[test]
    fn generated_thread_item_parses_mcp_arguments_json() {
        let item = generated::ThreadItem::McpToolCall {
            id: "mcp-1".into(),
            server: "filesystem".into(),
            tool: "read_file".into(),
            status: generated::McpToolCallStatus::Completed,
            arguments: serde_json::from_value(json!({"path": "/tmp/file.txt"}))
                .expect("json value should convert"),
            result: None,
            error: None,
            duration_ms: Some(42),
        };

        let upstream_item = convert_generated_thread_item(item).expect("mcp tool item should convert");
        let upstream::ThreadItem::McpToolCall { arguments, .. } = upstream_item else {
            panic!("expected mcp tool call");
        };
        assert_eq!(arguments.get("path").and_then(|value| value.as_str()), Some("/tmp/file.txt"));
    }

    #[test]
    fn generated_thread_item_parses_collab_agent_states_json() {
        let item = generated::ThreadItem::CollabAgentToolCall {
            id: "collab-1".into(),
            tool: generated::CollabAgentTool::SpawnAgent,
            status: generated::CollabAgentToolCallStatus::Completed,
            sender_thread_id: "parent-thread".into(),
            receiver_thread_ids: vec!["sub-thread-1".into()],
            prompt: Some("Review the changes".into()),
            model: None,
            reasoning_effort: None,
            agents_states: vec![generated::ThreadItemAgentsStatesEntry {
                key: "sub-thread-1".into(),
                value: generated::CollabAgentState {
                    status: generated::CollabAgentStatus::Running,
                    message: Some("Working".into()),
                },
            }],
        };

        let upstream_item =
            convert_generated_thread_item(item).expect("collab agent item should convert");
        let upstream::ThreadItem::CollabAgentToolCall { agents_states, .. } = upstream_item else {
            panic!("expected collab agent tool call");
        };
        let state = agents_states
            .get("sub-thread-1")
            .expect("collab state should be present");
        assert_eq!(state.status, upstream::CollabAgentStatus::Running);
        assert_eq!(state.message.as_deref(), Some("Working"));
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl EventSubscription {
    pub async fn next_event(&self) -> Result<UiEvent, ClientError> {
        let mut rx = {
            self.rx
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed("no subscriber".to_string()))?
        };
        let result = loop {
            match rx.recv().await {
                Ok(event) => break Ok(event),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break Err(ClientError::EventClosed("closed".to_string()));
                }
            }
        };
        *self.rx.lock().unwrap() = Some(rx);
        result
    }
}

/// Fully typed response from thread read/resume/fork/rollback with pre-hydrated conversation items.
#[derive(uniffi::Record)]
pub struct FfiSshBootstrapResult {
    pub server_port: u16,
    pub tunnel_local_port: u16,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
}

impl From<SshBootstrapResult> for FfiSshBootstrapResult {
    fn from(value: SshBootstrapResult) -> Self {
        Self {
            server_port: value.server_port,
            tunnel_local_port: value.tunnel_local_port,
            server_version: value.server_version,
            pid: value.pid,
        }
    }
}

#[derive(uniffi::Record)]
pub struct FfiMdnsSeed {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub service_type: String,
}

impl From<FfiMdnsSeed> for MdnsSeed {
    fn from(value: FfiMdnsSeed) -> Self {
        Self {
            name: value.name,
            host: value.host,
            port: value.port,
            service_type: value.service_type,
            txt: HashMap::new(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct FfiDiscoveredServer {
    pub id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub codex_port: Option<u16>,
    pub ssh_port: Option<u16>,
    pub source: String,
    pub reachable: bool,
}

impl From<crate::discovery::DiscoveredServer> for FfiDiscoveredServer {
    fn from(value: crate::discovery::DiscoveredServer) -> Self {
        Self {
            id: value.id,
            display_name: value.display_name,
            host: value.host,
            port: value.port,
            codex_port: value.codex_port,
            ssh_port: value.ssh_port,
            source: ffi_discovery_source(value.source).to_string(),
            reachable: value.reachable,
        }
    }
}

#[derive(uniffi::Record)]
pub struct FfiSshConnectionResult {
    pub session_id: String,
    pub normalized_host: String,
    pub server_port: u16,
    pub tunnel_local_port: Option<u16>,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
    pub wake_mac: Option<String>,
}

#[derive(uniffi::Record)]
pub struct FfiSshExecResult {
    pub exit_code: u32,
    pub stdout: String,
    pub stderr: String,
}

impl From<ExecResult> for FfiSshExecResult {
    fn from(value: ExecResult) -> Self {
        Self {
            exit_code: value.exit_code,
            stdout: value.stdout,
            stderr: value.stderr,
        }
    }
}

fn ffi_discovery_source(source: DiscoverySource) -> &'static str {
    match source {
        DiscoverySource::Bonjour | DiscoverySource::LanProbe | DiscoverySource::ArpScan => {
            "bonjour"
        }
        DiscoverySource::Tailscale => "tailscale",
        DiscoverySource::Manual => "manual",
        DiscoverySource::Bundled => "local",
    }
}

#[derive(uniffi::Record)]
pub struct HydratedConversationItem {
    pub id: String,
    pub content: HydratedConversationItemContent,
    pub source_turn_id: Option<String>,
    pub source_turn_index: Option<u32>,
    pub timestamp: Option<f64>,
    pub is_from_user_turn_boundary: bool,
}

#[derive(uniffi::Enum)]
pub enum HydratedConversationItemContent {
    User(HydratedUserMessageData),
    Assistant(HydratedAssistantMessageData),
    Reasoning(HydratedReasoningData),
    TodoList(HydratedTodoListData),
    ProposedPlan(HydratedProposedPlanData),
    CommandExecution(HydratedCommandExecutionData),
    FileChange(HydratedFileChangeData),
    McpToolCall(HydratedMcpToolCallData),
    DynamicToolCall(HydratedDynamicToolCallData),
    MultiAgentAction(HydratedMultiAgentActionData),
    WebSearch(HydratedWebSearchData),
    Divider(HydratedDividerData),
    Note(HydratedNoteData),
}

#[derive(uniffi::Record)]
pub struct HydratedUserMessageData {
    pub text: String,
    pub image_data_uris: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedAssistantMessageData {
    pub text: String,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedReasoningData {
    pub summary: Vec<String>,
    pub content: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedTodoListData {
    pub steps: Vec<HydratedPlanStep>,
}

#[derive(uniffi::Record)]
pub struct HydratedPlanStep {
    pub step: String,
    pub status: String,
}

#[derive(uniffi::Record)]
pub struct HydratedProposedPlanData {
    pub content: String,
}

#[derive(uniffi::Record)]
pub struct HydratedCommandExecutionData {
    pub command: String,
    pub cwd: String,
    pub status: String,
    pub output: Option<String>,
    pub exit_code: Option<i32>,
    pub duration_ms: Option<i64>,
    pub process_id: Option<String>,
    pub actions: Vec<HydratedCommandActionData>,
}

#[derive(uniffi::Record)]
pub struct HydratedCommandActionData {
    pub kind: String,
    pub command: String,
    pub name: Option<String>,
    pub path: Option<String>,
    pub query: Option<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedFileChangeData {
    pub status: String,
    pub changes: Vec<HydratedFileChangeEntryData>,
}

#[derive(uniffi::Record)]
pub struct HydratedFileChangeEntryData {
    pub path: String,
    pub kind: String,
    pub diff: String,
}

#[derive(uniffi::Record)]
pub struct HydratedMcpToolCallData {
    pub server: String,
    pub tool: String,
    pub status: String,
    pub duration_ms: Option<i64>,
    pub arguments_json: Option<String>,
    pub content_summary: Option<String>,
    pub structured_content_json: Option<String>,
    pub raw_output_json: Option<String>,
    pub error_message: Option<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedDynamicToolCallData {
    pub tool: String,
    pub status: String,
    pub duration_ms: Option<i64>,
    pub success: Option<bool>,
    pub arguments_json: Option<String>,
    pub content_summary: Option<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedMultiAgentStateData {
    pub target_id: String,
    pub status: String,
    pub message: Option<String>,
}

#[derive(uniffi::Record)]
pub struct HydratedMultiAgentActionData {
    pub tool: String,
    pub status: String,
    pub prompt: Option<String>,
    pub targets: Vec<String>,
    pub receiver_thread_ids: Vec<String>,
    pub agent_states: Vec<HydratedMultiAgentStateData>,
}

#[derive(uniffi::Record)]
pub struct HydratedWebSearchData {
    pub query: String,
    pub action_json: Option<String>,
    pub is_in_progress: bool,
}

#[derive(uniffi::Enum)]
pub enum HydratedDividerData {
    ContextCompaction { is_complete: bool },
    ReviewEntered { review: String },
    ReviewExited { review: String },
}

#[derive(uniffi::Record)]
pub struct HydratedNoteData {
    pub title: String,
    pub body: String,
}

impl From<crate::conversation::ConversationItem> for HydratedConversationItem {
    fn from(value: crate::conversation::ConversationItem) -> Self {
        Self {
            id: value.id,
            content: value.content.into(),
            source_turn_id: value.source_turn_id,
            source_turn_index: value.source_turn_index.map(|index| index as u32),
            timestamp: value.timestamp,
            is_from_user_turn_boundary: value.is_from_user_turn_boundary,
        }
    }
}

impl From<crate::conversation::ConversationItemContent> for HydratedConversationItemContent {
    fn from(value: crate::conversation::ConversationItemContent) -> Self {
        use crate::conversation::ConversationItemContent as ItemContent;

        match value {
            ItemContent::User(data) => Self::User(HydratedUserMessageData {
                text: data.text,
                image_data_uris: data.image_data_uris,
            }),
            ItemContent::Assistant(data) => Self::Assistant(HydratedAssistantMessageData {
                text: data.text,
                agent_nickname: data.agent_nickname,
                agent_role: data.agent_role,
            }),
            ItemContent::Reasoning(data) => Self::Reasoning(HydratedReasoningData {
                summary: data.summary,
                content: data.content,
            }),
            ItemContent::TodoList(data) => Self::TodoList(HydratedTodoListData {
                steps: data.steps.into_iter().map(Into::into).collect(),
            }),
            ItemContent::ProposedPlan(data) => {
                Self::ProposedPlan(HydratedProposedPlanData { content: data.content })
            }
            ItemContent::CommandExecution(data) => {
                Self::CommandExecution(HydratedCommandExecutionData {
                    command: data.command,
                    cwd: data.cwd,
                    status: data.status,
                    output: data.output,
                    exit_code: data.exit_code,
                    duration_ms: data.duration_ms,
                    process_id: data.process_id,
                    actions: data.actions.into_iter().map(Into::into).collect(),
                })
            }
            ItemContent::FileChange(data) => Self::FileChange(HydratedFileChangeData {
                status: data.status,
                changes: data.changes.into_iter().map(Into::into).collect(),
            }),
            ItemContent::McpToolCall(data) => Self::McpToolCall(HydratedMcpToolCallData {
                server: data.server,
                tool: data.tool,
                status: data.status,
                duration_ms: data.duration_ms,
                arguments_json: data.arguments_json,
                content_summary: data.content_summary,
                structured_content_json: data.structured_content_json,
                raw_output_json: data.raw_output_json,
                error_message: data.error_message,
            }),
            ItemContent::DynamicToolCall(data) => {
                Self::DynamicToolCall(HydratedDynamicToolCallData {
                    tool: data.tool,
                    status: data.status,
                    duration_ms: data.duration_ms,
                    success: data.success,
                    arguments_json: data.arguments_json,
                    content_summary: data.content_summary,
                })
            }
            ItemContent::MultiAgentAction(data) => {
                Self::MultiAgentAction(HydratedMultiAgentActionData {
                    tool: data.tool,
                    status: data.status,
                    prompt: data.prompt,
                    targets: data.targets,
                    receiver_thread_ids: data.receiver_thread_ids,
                    agent_states: data.agent_states.into_iter().map(Into::into).collect(),
                })
            }
            ItemContent::WebSearch(data) => Self::WebSearch(HydratedWebSearchData {
                query: data.query,
                action_json: data.action_json,
                is_in_progress: data.is_in_progress,
            }),
            ItemContent::Divider(data) => Self::Divider(data.into()),
            ItemContent::Note(data) => Self::Note(HydratedNoteData {
                title: data.title,
                body: data.body,
            }),
        }
    }
}

impl From<crate::conversation::PlanStep> for HydratedPlanStep {
    fn from(value: crate::conversation::PlanStep) -> Self {
        Self {
            step: value.step,
            status: value.status,
        }
    }
}

impl From<crate::conversation::CommandActionData> for HydratedCommandActionData {
    fn from(value: crate::conversation::CommandActionData) -> Self {
        Self {
            kind: value.kind,
            command: value.command,
            name: value.name,
            path: value.path,
            query: value.query,
        }
    }
}

impl From<crate::conversation::FileChangeEntryData> for HydratedFileChangeEntryData {
    fn from(value: crate::conversation::FileChangeEntryData) -> Self {
        Self {
            path: value.path,
            kind: value.kind,
            diff: value.diff,
        }
    }
}

impl From<crate::conversation::MultiAgentStateData> for HydratedMultiAgentStateData {
    fn from(value: crate::conversation::MultiAgentStateData) -> Self {
        Self {
            target_id: value.target_id,
            status: value.status,
            message: value.message,
        }
    }
}

impl From<crate::conversation::DividerData> for HydratedDividerData {
    fn from(value: crate::conversation::DividerData) -> Self {
        match value {
            crate::conversation::DividerData::ContextCompaction { is_complete } => {
                Self::ContextCompaction { is_complete }
            }
            crate::conversation::DividerData::ReviewEntered { review } => {
                Self::ReviewEntered { review }
            }
            crate::conversation::DividerData::ReviewExited { review } => {
                Self::ReviewExited { review }
            }
        }
    }
}

/// Fully typed response from thread read/resume/fork/rollback with pre-hydrated conversation items.
#[derive(uniffi::Record)]
pub struct ThreadResponseWithHydration {
    // ── Thread metadata ──
    pub thread_id: String,
    pub thread_path: Option<String>,
    pub turn_count: u32,
    pub last_turn_status: Option<String>,
    // ── Agent lineage (extracted from source.threadSpawn) ──
    pub parent_thread_id: Option<String>,
    pub root_thread_id: Option<String>,
    pub agent_id: Option<String>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    // ── Session metadata ──
    pub model: Option<String>,
    pub model_provider: Option<String>,
    pub cwd: Option<String>,
    pub reasoning_effort: Option<String>,
    // ── Hydrated conversation items (typed) ──
    pub hydrated_conversation_items: Vec<HydratedConversationItem>,
}

impl CodexClient {
    fn ssh_session(&self, session_id: &str) -> Result<Arc<SshClient>, ClientError> {
        self.ssh_sessions
            .lock()
            .expect("ssh_sessions lock poisoned")
            .get(session_id)
            .map(|session| Arc::clone(&session.client))
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })
    }

    async fn ssh_read_wake_mac(&self, session: Arc<SshClient>) -> Option<String> {
        const WAKE_MAC_SCRIPT: &str = r#"iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "$iface" ]; then iface="en0"; fi
mac="$(ifconfig "$iface" 2>/dev/null | awk '/ether /{print $2; exit}')"
if [ -z "$mac" ]; then
  mac="$(ifconfig en0 2>/dev/null | awk '/ether /{print $2; exit}')"
fi
if [ -z "$mac" ]; then
  mac="$(ifconfig 2>/dev/null | awk '/ether /{print $2; exit}')"
fi
printf '%s' "$mac""#;
        let rt = Arc::clone(&self.rt);
        let result = tokio::task::spawn_blocking(move || {
            rt.block_on(async move { session.exec(WAKE_MAC_SCRIPT).await.map_err(map_ssh_error) })
        })
        .await
        .ok()?
        .ok()?;
        if result.exit_code != 0 {
            return None;
        }
        normalize_wake_mac(&result.stdout)
    }

    fn thread_read_params(thread_id: String, include_turns: bool) -> generated::ThreadReadParams {
        generated::ThreadReadParams {
            thread_id,
            include_turns,
        }
    }

    fn thread_resume_params(
        thread_id: String,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
    ) -> Result<generated::ThreadResumeParams, ClientError> {
        Ok(generated::ThreadResumeParams {
            thread_id,
            history: None,
            path: None,
            model: None,
            model_provider: None,
            service_tier: None,
            cwd,
            approval_policy,
            approvals_reviewer: None,
            sandbox,
            config: None,
            base_instructions: None,
            developer_instructions,
            personality: None,
            persist_extended_history: false,
        })
    }

    fn thread_fork_params(
        thread_id: String,
        cwd: Option<String>,
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
    ) -> Result<generated::ThreadForkParams, ClientError> {
        Ok(generated::ThreadForkParams {
            thread_id,
            path: None,
            model: None,
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
            persist_extended_history: false,
        })
    }

    fn thread_rollback_params(
        thread_id: String,
        num_turns: u32,
    ) -> generated::ThreadRollbackParams {
        generated::ThreadRollbackParams {
            thread_id,
            num_turns,
        }
    }

    fn hydrate_serializable_response<T: serde::Serialize>(
        &self,
        response: &T,
    ) -> Result<ThreadResponseWithHydration, ClientError> {
        let result = serde_json::to_value(response)
            .map_err(|e| ClientError::Serialization(e.to_string()))?;
        self.build_hydrated_response(&result)
    }

    /// Build a fully typed ThreadResponseWithHydration from a raw server response.
    fn build_hydrated_response(
        &self,
        response: &serde_json::Value,
    ) -> Result<ThreadResponseWithHydration, ClientError> {
        use crate::conversation::{HydrationOptions, hydrate_turns};
        use codex_app_server_protocol::Turn;

        let thread = response.get("thread").unwrap_or(response);

        // Hydrate turns
        let turns_value = thread
            .get("turns")
            .cloned()
            .unwrap_or(serde_json::Value::Array(vec![]));
        let turns: Vec<Turn> = serde_json::from_value(turns_value)
            .map_err(|e| ClientError::Serialization(format!("failed to parse turns: {e}")))?;

        // Extract thread metadata
        let thread_id = thread
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let thread_path = thread
            .get("path")
            .and_then(|v| v.as_str())
            .map(String::from);
        let turn_count = turns.len() as u32;
        let last_turn_status = turns
            .last()
            .and_then(|t| serde_json::to_value(&t.status).ok())
            .and_then(|v| v.as_str().map(String::from));

        // Extract agent lineage from source.threadSpawn
        let source = thread.get("source");
        let thread_spawn = source
            .and_then(|s| s.get("SubAgent"))
            .and_then(|sa| sa.get("ThreadSpawn"));
        let parent_thread_id = thread_spawn
            .and_then(|ts| {
                ts.get("parent_thread_id")
                    .or_else(|| ts.get("parentThreadId"))
            })
            .and_then(|v| v.as_str())
            .map(String::from);
        let root_thread_id = thread
            .get("rootThreadId")
            .or_else(|| thread.get("root_thread_id"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let agent_id = thread
            .get("agentId")
            .or_else(|| thread.get("agent_id"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let agent_nickname = thread
            .get("agentNickname")
            .or_else(|| thread.get("agent_nickname"))
            .or_else(|| {
                thread_spawn
                    .and_then(|ts| ts.get("agent_nickname").or_else(|| ts.get("agentNickname")))
            })
            .and_then(|v| v.as_str())
            .map(String::from);
        let agent_role = thread
            .get("agentRole")
            .or_else(|| thread.get("agent_role"))
            .or_else(|| thread.get("agentType"))
            .or_else(|| thread.get("agent_type"))
            .or_else(|| {
                thread_spawn.and_then(|ts| {
                    ts.get("agent_role")
                        .or_else(|| ts.get("agentRole"))
                        .or_else(|| ts.get("agent_type"))
                        .or_else(|| ts.get("agentType"))
                })
            })
            .and_then(|v| v.as_str())
            .map(String::from);

        let hydration_opts = HydrationOptions {
            default_agent_nickname: agent_nickname.clone(),
            default_agent_role: agent_role.clone(),
        };

        // Session metadata
        let model = response
            .get("model")
            .and_then(|v| v.as_str())
            .map(String::from);
        let model_provider = response
            .get("modelProvider")
            .or_else(|| response.get("model_provider"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let cwd = response
            .get("cwd")
            .and_then(|v| v.as_str())
            .map(String::from)
            .or_else(|| thread_path.clone());
        let reasoning_effort = response
            .get("reasoningEffort")
            .or_else(|| response.get("reasoning_effort"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let hydrated_conversation_items = hydrate_turns(&turns, &hydration_opts)
            .into_iter()
            .map(Into::into)
            .collect();

        Ok(ThreadResponseWithHydration {
            thread_id,
            thread_path,
            turn_count,
            last_turn_status,
            parent_thread_id,
            root_thread_id,
            agent_id,
            agent_nickname,
            agent_role,
            model,
            model_provider,
            cwd,
            reasoning_effort,
            hydrated_conversation_items,
        })
    }

    /// Internal: send a response to a server request on the correct session.
    async fn respond_internal(
        &self,
        server_id: &str,
        request_id: &str,
        result: serde_json::Value,
    ) -> Result<(), ClientError> {
        let sid = server_id.to_string();
        let id = serde_json::Value::String(request_id.to_string());
        let rt = Arc::clone(&self.rt);
        let inner = Arc::clone(&self.inner);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async {
                inner
                    .respond_for_server(&sid, id, result)
                    .await
                    .map_err(|e| ClientError::Rpc(e))
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))??;
        Ok(())
    }

    async fn reject_internal(
        &self,
        server_id: &str,
        request_id: &str,
        error: upstream::JSONRPCErrorError,
    ) -> Result<(), ClientError> {
        let sid = server_id.to_string();
        let id = serde_json::Value::String(request_id.to_string());
        let rt = Arc::clone(&self.rt);
        let inner = Arc::clone(&self.inner);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async {
                inner
                    .reject_for_server(&sid, id, error)
                    .await
                    .map_err(ClientError::Rpc)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))??;
        Ok(())
    }

    /// Send a typed ClientRequest and deserialize the response.
    pub(crate) async fn request_typed<R: serde::de::DeserializeOwned + Send + 'static>(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<R, ClientError> {
        let sid = server_id.to_string();
        let rt = Arc::clone(&self.rt);
        let inner = Arc::clone(&self.inner);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async {
                inner
                    .request_typed_for_server::<R>(&sid, request)
                    .await
                    .map_err(|e| ClientError::Rpc(e))
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?
    }

    /// Internal: await the next event from the broadcast channel.
    async fn next_event_internal(&self) -> Result<UiEvent, ClientError> {
        let mut rx = {
            self.event_rx
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed("no subscriber".to_string()))?
        };
        let result = loop {
            match rx.recv().await {
                Ok(event) => break Ok(event),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break Err(ClientError::EventClosed("closed".to_string()));
                }
            }
        };
        *self.event_rx.lock().unwrap() = Some(rx);
        result
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ClientError {
    #[error("Transport: {0}")]
    Transport(String),
    #[error("RPC: {0}")]
    Rpc(String),
    #[error("Invalid params: {0}")]
    InvalidParams(String),
    #[error("Serialization: {0}")]
    Serialization(String),
    #[error("Event stream closed: {0}")]
    EventClosed(String),
}

fn map_ssh_error(error: SshError) -> ClientError {
    match error {
        SshError::ConnectionFailed(message)
        | SshError::AuthFailed(message)
        | SshError::PortForwardFailed(message)
        | SshError::ExecFailed {
            stderr: message, ..
        } => ClientError::Transport(message),
        SshError::HostKeyVerification { fingerprint } => {
            ClientError::Transport(format!("host key verification failed: {fingerprint}"))
        }
        SshError::Timeout => ClientError::Transport("SSH operation timed out".into()),
        SshError::Disconnected => ClientError::Transport("SSH session disconnected".into()),
    }
}

fn ssh_auth(
    password: Option<String>,
    private_key_pem: Option<String>,
    passphrase: Option<String>,
) -> Result<SshAuth, ClientError> {
    match (password, private_key_pem) {
        (Some(password), None) => Ok(SshAuth::Password(password)),
        (None, Some(key_pem)) => Ok(SshAuth::PrivateKey {
            key_pem,
            passphrase,
        }),
        (None, None) => Err(ClientError::InvalidParams(
            "missing SSH credential: provide either password or private key".into(),
        )),
        (Some(_), Some(_)) => Err(ClientError::InvalidParams(
            "ambiguous SSH credentials: provide either password or private key, not both".into(),
        )),
    }
}

fn normalize_ssh_host(host: &str) -> String {
    let mut normalized = host.trim().trim_matches(['[', ']']).replace("%25", "%");
    if !normalized.contains(':') {
        if let Some((base, _scope)) = normalized.split_once('%') {
            normalized = base.to_string();
        }
    }
    normalized
}

fn normalize_wake_mac(raw: &str) -> Option<String> {
    let compact = raw
        .trim()
        .replace(':', "")
        .replace('-', "")
        .to_ascii_lowercase();
    if compact.len() != 12 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }

    let mut chunks = Vec::with_capacity(6);
    for index in (0..12).step_by(2) {
        chunks.push(compact[index..index + 2].to_string());
    }
    Some(chunks.join(":"))
}
