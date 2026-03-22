use std::ffi::c_void;
use std::fs;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, OnceLock};
use tokio::runtime::Runtime;

#[cfg(target_os = "ios")]
mod aec;
#[cfg(target_os = "ios")]
mod ios_exec;
pub mod voice_handoff;

#[cfg(target_os = "android")]
mod android_jni;
#[cfg(target_os = "ios")]
mod ios_exec;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to create tokio runtime")
    })
}

// ---------------------------------------------------------------------------
// Callback infrastructure
// ---------------------------------------------------------------------------

/// Callback invoked from a background thread for every server-to-client message.
/// `json` is a UTF-8 JSON-RPC line. The callback must not block.
type MessageCallback = unsafe extern "C" fn(ctx: *mut c_void, json: *const c_char, json_len: usize);

/// Send-safe wrapper for delivering JSON messages to the native callback.
/// Bundles the function pointer and context pointer together with a
/// closed flag to prevent use-after-free on the native side.
#[derive(Clone)]
struct CallbackHandle {
    cb: MessageCallback,
    ctx: *mut c_void,
    closed: Arc<std::sync::atomic::AtomicBool>,
}
unsafe impl Send for CallbackHandle {}
unsafe impl Sync for CallbackHandle {}

impl CallbackHandle {
    unsafe fn deliver(&self, json: &str) {
        if self.closed.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        unsafe {
            (self.cb)(self.ctx, json.as_ptr() as *const c_char, json.len());
        }
    }

    fn mark_closed(&self) {
        self.closed
            .store(true, std::sync::atomic::Ordering::Release);
    }
}

// ===========================================================================
// MobileClient FFI — unified API
// ===========================================================================

use codex_mobile_client::MobileClient;
use codex_mobile_client::session::connection::ServerConfig;
use codex_mobile_client::session::connection::InProcessConfig;

/// Opaque state held behind the MobileClient FFI handle pointer.
struct MobileClientState {
    client: Arc<MobileClient>,
    cb_handle: CallbackHandle,
    event_task: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

// SAFETY: MobileClient is Send + Sync. The CallbackHandle is Send + Sync
// by the same invariant as the channel API above.
unsafe impl Send for MobileClientState {}
unsafe impl Sync for MobileClientState {}

/// Create a new `MobileClient` with an in-memory auth storage.
///
/// `callback` will be used for event delivery (via `codex_mobile_client_subscribe_events`).
/// On success writes an opaque handle to `*out_handle` and returns 0.
#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_client_init(
    callback: MessageCallback,
    callback_ctx: *mut c_void,
    out_handle: *mut *mut c_void,
) -> i32 {
    if out_handle.is_null() {
        return -1;
    }

    init_codex_home();
    #[cfg(target_os = "ios")]
    init_tls_roots();
    #[cfg(target_os = "ios")]
    {
        ios_exec::init();
        codex_core::exec::set_ios_exec_hook(ios_exec::run_command);
    }

    eprintln!("[codex-mobile-client] creating MobileClient");

    let closed_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let cb_handle = CallbackHandle {
        cb: callback,
        ctx: callback_ctx,
        closed: closed_flag,
    };

    let client = Arc::new(MobileClient::new());

    let state = Box::new(MobileClientState {
        client,
        cb_handle,
        event_task: std::sync::Mutex::new(None),
    });

    unsafe {
        *out_handle = Box::into_raw(state) as *mut c_void;
    }

    eprintln!("[codex-mobile-client] init complete");
    0
}

/// Destroy a `MobileClient` and free all resources.
#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_client_destroy(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let state = unsafe { Box::from_raw(handle as *mut MobileClientState) };

    // Mark closed FIRST — prevents in-flight callbacks from touching freed memory.
    state.cb_handle.mark_closed();

    // Abort the event subscription task if running.
    if let Ok(mut guard) = state.event_task.lock() {
        if let Some(task) = guard.take() {
            task.abort();
            runtime().block_on(async { let _ = task.await; });
        }
    }

    eprintln!("[codex-mobile-client] destroyed");
}

/// Generic JSON-RPC style call into `MobileClient`.
///
/// Takes a JSON string like `{"method": "connect_local", "params": {...}}` and
/// dispatches to the appropriate `MobileClient` method. The result is delivered
/// via `response_cb` as a JSON string.
///
/// Returns 0 if the call was dispatched, negative on immediate failure.
#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_client_call(
    handle: *mut c_void,
    method_json: *const c_char,
    method_json_len: usize,
    response_cb: MessageCallback,
    response_ctx: *mut c_void,
) -> i32 {
    if handle.is_null() || method_json.is_null() {
        return -1;
    }

    let state = unsafe { &*(handle as *const MobileClientState) };
    let json_bytes = unsafe { std::slice::from_raw_parts(method_json as *const u8, method_json_len) };
    let json_str = match std::str::from_utf8(json_bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => return -2,
    };

    let envelope: serde_json::Value = match serde_json::from_str(&json_str) {
        Ok(v) => v,
        Err(_) => return -3,
    };

    let method = match envelope.get("method").and_then(|m| m.as_str()) {
        Some(m) => m.to_owned(),
        None => return -4,
    };

    let params = envelope.get("params").cloned().unwrap_or(serde_json::Value::Null);

    let resp_closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let resp_handle = CallbackHandle {
        cb: response_cb,
        ctx: response_ctx,
        closed: resp_closed,
    };

    let client = Arc::clone(&state.client);

    runtime().spawn_blocking(move || {
        let result = runtime().block_on(client.dispatch_json(&method, params));

        let response_json = match result {
            Ok(value) => serde_json::json!({ "ok": true, "result": value }),
            Err(err) => serde_json::json!({ "ok": false, "error": err }),
        };

        if let Ok(json) = serde_json::to_string(&response_json) {
            unsafe { resp_handle.deliver(&json); }
        }
    });

    0
}

/// Register a callback for `UiEvent` delivery.
///
/// Spawns a tokio task that reads from `subscribe_ui_events()` and calls the
/// callback for each event (serialized as JSON). Only one subscription is
/// active at a time — calling again replaces the previous one.
///
/// Returns 0 on success, negative on failure.
#[unsafe(no_mangle)]
pub extern "C" fn codex_mobile_client_subscribe_events(
    handle: *mut c_void,
    callback: MessageCallback,
    callback_ctx: *mut c_void,
) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let state = unsafe { &*(handle as *const MobileClientState) };

    let closed_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let event_cb = CallbackHandle {
        cb: callback,
        ctx: callback_ctx,
        closed: closed_flag,
    };

    let mut rx = state.client.subscribe_ui_events();

    // Abort previous subscription if any.
    if let Ok(mut guard) = state.event_task.lock() {
        if let Some(old_task) = guard.take() {
            old_task.abort();
        }

        let task = runtime().spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => {
                        if let Ok(json) = serde_json::to_string(&event) {
                            unsafe { event_cb.deliver(&json); }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        eprintln!("[codex-mobile-client] event subscription lagged {n}");
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        eprintln!("[codex-mobile-client] event channel closed");
                        break;
                    }
                }
            }
        });

        *guard = Some(task);
    } else {
        return -2;
    }

    0
}


fn init_codex_home() {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(existing) = std::env::var("CODEX_HOME") {
        candidates.push(PathBuf::from(existing));
    }

    if let Ok(home) = std::env::var("HOME") {
        let home = PathBuf::from(home);
        #[cfg(target_os = "ios")]
        {
            candidates.push(
                home.join("Library")
                    .join("Application Support")
                    .join("codex"),
            );
            candidates.push(home.join("Documents").join(".codex"));
        }
        candidates.push(home.join(".codex"));
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        candidates.push(PathBuf::from(tmpdir).join("codex-home"));
    }

    for codex_home in candidates {
        match fs::create_dir_all(&codex_home) {
            Ok(()) => {
                // SAFETY: called before app-server runtime starts handling requests.
                unsafe {
                    std::env::set_var("CODEX_HOME", &codex_home);
                }
                eprintln!("[codex-bridge] CODEX_HOME={}", codex_home.display());
                return;
            }
            Err(err) => {
                eprintln!(
                    "[codex-bridge] failed to create CODEX_HOME candidate {:?}: {err}",
                    codex_home
                );
            }
        }
    }

    eprintln!("[codex-bridge] unable to initialize any writable CODEX_HOME location");
}

#[cfg(target_os = "ios")]
fn init_tls_roots() {
    if let Some(existing) = std::env::var_os("SSL_CERT_FILE") {
        let existing_path = PathBuf::from(existing);
        if existing_path.is_file() {
            return;
        }
        eprintln!(
            "[codex-bridge] replacing stale SSL_CERT_FILE {}",
            existing_path.display()
        );
    }

    let codex_home = match std::env::var("CODEX_HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return,
    };
    let pem_path = codex_home.join("cacert.pem");
    if !pem_path.exists() {
        static CACERT_PEM: &[u8] = include_bytes!("cacert.pem");
        if let Err(e) = fs::write(&pem_path, CACERT_PEM) {
            eprintln!("[codex-bridge] failed to write cacert.pem: {e}");
            return;
        }
    }
    unsafe {
        std::env::set_var("SSL_CERT_FILE", &pem_path);
    }
    eprintln!("[codex-bridge] SSL_CERT_FILE={}", pem_path.display());
}

// ===========================================================================
// Conversation hydration FFI
// ===========================================================================

use codex_mobile_client::conversation::{hydrate_turns, HydrationOptions};
use codex_app_server_protocol::Turn;

/// Hydrate a JSON array of upstream `Turn` objects into a JSON array of
/// `ConversationItem` suitable for UI rendering.
///
/// `turns_json` / `turns_json_len` must point to a valid UTF-8 JSON string
/// representing `Vec<Turn>`.
///
/// Returns a heap-allocated null-terminated UTF-8 JSON string on success
/// (caller must free with `codex_free_string`), or null on failure.
/// The output length (excluding the null terminator) is written to `*out_len`.
#[unsafe(no_mangle)]
pub extern "C" fn codex_hydrate_turns(
    turns_json: *const c_char,
    turns_json_len: usize,
    out_len: *mut usize,
) -> *mut c_char {
    if turns_json.is_null() || out_len.is_null() {
        return std::ptr::null_mut();
    }

    let json_bytes = unsafe { std::slice::from_raw_parts(turns_json as *const u8, turns_json_len) };
    let json_str = match std::str::from_utf8(json_bytes) {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    let turns: Vec<Turn> = match serde_json::from_str(json_str) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("[codex-bridge] codex_hydrate_turns: failed to parse turns: {e}");
            return std::ptr::null_mut();
        }
    };

    let items = hydrate_turns(&turns, &HydrationOptions::default());

    let result_json = match serde_json::to_string(&items) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[codex-bridge] codex_hydrate_turns: failed to serialize: {e}");
            return std::ptr::null_mut();
        }
    };

    unsafe { *out_len = result_json.len(); }

    // Convert to a C string (null-terminated, heap-allocated).
    let c_string = match std::ffi::CString::new(result_json) {
        Ok(cs) => cs,
        Err(_) => return std::ptr::null_mut(),
    };
    c_string.into_raw()
}

/// Free a string returned by `codex_hydrate_turns`.
#[unsafe(no_mangle)]
pub extern "C" fn codex_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { let _ = std::ffi::CString::from_raw(ptr); }
    }
}
