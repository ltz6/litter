//! Mobile-owned server request projections.
//!
//! Upstream/generated request and response wrappers are the canonical protocol
//! surface. This module is reserved for UI-specific projections that do not
//! exist upstream.

use serde::{Deserialize, Serialize};

use super::enums::ApprovalKind;

/// A pending approval request from the server that needs user action.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct PendingApproval {
    /// The JSON-RPC request ID as a string (could originally be string or integer).
    pub id: String,
    /// What kind of approval is being requested.
    pub kind: ApprovalKind,
    /// Thread this approval belongs to.
    pub thread_id: Option<String>,
    /// Turn this approval belongs to.
    pub turn_id: Option<String>,
    /// Item ID this approval is associated with.
    pub item_id: Option<String>,
    /// The command to approve, if applicable.
    pub command: Option<String>,
    /// The file path involved, if applicable.
    pub path: Option<String>,
    /// Working directory for the command, if applicable.
    pub cwd: Option<String>,
    /// Human-readable reason/explanation for the approval request.
    pub reason: Option<String>,
    /// Raw params from the server request as JSON string for forward compatibility.
    #[serde(default)]
    pub raw_params_json: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::ApprovalKind;

    #[test]
    fn pending_approval_roundtrip() {
        let approval = PendingApproval {
            id: "42".to_string(),
            kind: ApprovalKind::Command,
            thread_id: Some("thr_123".to_string()),
            turn_id: Some("turn_456".to_string()),
            item_id: Some("item_789".to_string()),
            command: Some("rm -rf /tmp/test".to_string()),
            path: None,
            cwd: Some("/home/user".to_string()),
            reason: Some("Command needs approval".to_string()),
            raw_params_json: "{}".to_string(),
        };
        let json = serde_json::to_string(&approval).unwrap();
        let deserialized: PendingApproval = serde_json::from_str(&json).unwrap();
        assert_eq!(approval, deserialized);
    }

    #[test]
    fn pending_approval_file_change() {
        let approval = PendingApproval {
            id: "req-abc".to_string(),
            kind: ApprovalKind::FileChange,
            thread_id: Some("thr_123".to_string()),
            turn_id: Some("turn_456".to_string()),
            item_id: Some("item_789".to_string()),
            command: None,
            path: Some("/home/user/main.rs".to_string()),
            cwd: None,
            reason: Some("File modification requested".to_string()),
            raw_params_json: r#"{"diff":"+new line"}"#.to_string(),
        };
        let json = serde_json::to_string(&approval).unwrap();
        let deserialized: PendingApproval = serde_json::from_str(&json).unwrap();
        assert_eq!(approval, deserialized);
    }

    #[test]
    fn pending_approval_minimal() {
        let approval = PendingApproval {
            id: "1".to_string(),
            kind: ApprovalKind::Permissions,
            thread_id: None,
            turn_id: None,
            item_id: None,
            command: None,
            path: None,
            cwd: None,
            reason: None,
            raw_params_json: "null".to_string(),
        };
        let json = serde_json::to_value(&approval).unwrap();
        assert_eq!(json["id"], "1");
        assert!(json["threadId"].is_null());
    }
}
