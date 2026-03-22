//! FFI layer for iOS and Android consumption.
//!
//! Uses UniFFI proc-macro approach for automatic Swift/Kotlin binding generation.
//! The scaffolding macro is invoked in lib.rs; this module holds additional
//! FFI helper types and exported functions.

#[path = "codegen_rpc.generated.rs"]
pub mod generated_rpc;
pub mod uniffi_exports;
