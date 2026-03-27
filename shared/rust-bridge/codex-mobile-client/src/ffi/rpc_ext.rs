use crate::ffi::ClientError;
use crate::ffi::rpc::AppServerRpc;
use crate::ffi::shared::blocking_async;
use std::sync::Arc;

#[uniffi::export(async_runtime = "tokio")]
impl AppServerRpc {
    pub async fn start_remote_ssh_oauth_login(
        &self,
        server_id: String,
    ) -> Result<String, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.start_remote_ssh_oauth_login(&server_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }
}
