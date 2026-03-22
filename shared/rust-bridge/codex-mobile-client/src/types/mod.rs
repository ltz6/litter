//! FFI-exportable wrapper types for all Codex protocol messages.
//!
//! Auto-generated types from upstream in `generated` are the canonical source.
//! Hand-maintained types in `enums`, `models`, and `server_requests` provide
//! mobile-specific types and UniFFI derives for types not in upstream.

pub mod enums;
pub mod models;
pub mod server_requests;

/// Auto-generated wrapper types from upstream `codex-app-server-protocol`.
#[path = "codegen_types.generated.rs"]
pub mod generated;

// Re-export hand-maintained types.
pub use enums::*;
pub use models::*;
pub use server_requests::*;

// Re-export the upstream protocol crate.
pub use codex_app_server_protocol as upstream_protocol;
