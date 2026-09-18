mod chat;
mod receive_tx;
mod util;

use crate::nse::chat::handle_chat_notification;
use crate::nse::receive_tx::handle_receive_tx_notification;
use crate::types::Network;
use crate::util::MannaError;
use serde::Deserialize;
use serde_json::Value;
use std::error::Error;
use tracing::instrument;

uniffi::setup_scaffolding!();

#[derive(Deserialize, uniffi::Record, Debug)]
pub struct NotificationInfo {
    pub title: Option<String>,
    pub body: Option<String>,
    pub thread_id: Option<String>,
    pub sender_picture: Option<String>,
    pub payload: Option<String>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum NSEError {
    #[error("Decryption failed")]
    DecryptionFailed,
    #[error("Encryption failed")]
    EncryptionFailed,
    #[error("Network error: {0}")]
    Network(String),
    #[error("Swap error: {0}")]
    Swap(String),
    #[error("Base64 decode error: {0}")]
    Base64Decode(String),
    #[error("Invalid data : {0}")]
    InvalidData(String),
    #[error("File I/O error: {0}")]
    File(String),
    #[error("JWT token error")]
    Jwt(),
    #[error("Invalid File Data: {0}")]
    InvalidFileData(String),
    #[error("Message decryption failed: {0}")]
    MessageDecryptionFailed(String),
    #[error("LWK error: {0}")]
    LWK(String),
    #[error("Manna error: {0}")]
    Manna(String),
}

impl From<MannaError> for NSEError {
    fn from(value: MannaError) -> Self {
        NSEError::Manna(value.msg)
    }
}

#[uniffi::export]
#[instrument(err, skip_all)]
pub fn handle_notification(
    app_group_dir_path: String,
    log_dir_path: String,
    payload_json_str: String,
    file_password: Vec<u8>,
    jwt_tokens: Vec<String>,
) -> Result<Vec<NotificationInfo>, NSEError> {
    crate::logger::init_logger(log_dir_path, "NSE".to_string());

    let jwt_tokens: [String; 3] = jwt_tokens
        .try_into()
        .map_err(|_| NSEError::InvalidData("Expected 3 tokens".to_string()))?;

    let notification_data: Value = serde_json::from_str(&payload_json_str).map_err(|e| {
        e.source();
        NSEError::InvalidData(e.to_string())
    })?;
    tracing::info!("started notification handler!");

    let enc_key: [u8; 32] = file_password
        .try_into()
        .map_err(|_| NSEError::InvalidData("invalid length of file password".into()))?;

    let msg_type = notification_data["type"].as_str();
    if let Some(msg_type) = msg_type {
        let network = match notification_data["network"]
            .as_str()
            .map(|t| t.to_lowercase())
            .unwrap_or("".to_string())
            .as_str()
        {
            "mainnet" => Network::Mainnet,
            "testnet" => Network::Testnet,
            "regtest" => Network::Regtest,
            &_ => Network::Mainnet,
        };

        if msg_type == "new_message_chat" {
            return Ok(vec![handle_chat_notification(
                &network,
                notification_data,
                app_group_dir_path,
                enc_key,
                jwt_tokens,
            )?]);
        } else if msg_type == "received_tx" {
            return Ok(vec![handle_receive_tx_notification(
                &network,
                notification_data,
                app_group_dir_path,
                enc_key,
            )?]);
        }
    }

    Ok(vec![])
}
