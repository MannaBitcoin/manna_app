use crate::nse::NSEError;
use aes_gcm::{AeadCore, Aes256Gcm, KeyInit, Nonce, aead::Aead};
use bip39::rand::thread_rng;
use serde::Serialize;
use serde_json::Value;

pub(super) fn decrypt_file(file_path: &String, key: [u8; 32]) -> Result<Value, NSEError> {
    let encrypted_data = std::fs::read(file_path).map_err(|e| NSEError::File(e.to_string()))?;

    if encrypted_data.len() < 12 + 16 {
        return Err(NSEError::DecryptionFailed);
    }

    let nonce = Nonce::from_slice(&encrypted_data[0..12]);
    let ciphertext_with_tag = &encrypted_data[12..];
    
    let cipher = Aes256Gcm::new(&key.into());
    let plaintext = cipher
        .decrypt(nonce, ciphertext_with_tag)
        .map_err(|_| NSEError::DecryptionFailed)?;

    let json_str = String::from_utf8(plaintext).map_err(|_| NSEError::DecryptionFailed)?;
    serde_json::from_str(&json_str).map_err(|_| NSEError::DecryptionFailed)
}

pub(super) fn encrypt_and_save_file<T: Serialize>(
    file_path: &str,
    key: [u8; 32],
    data: &T,
) -> Result<(), NSEError> {
    let json_str = serde_json::to_string(&data)
        .map_err(|_| NSEError::File("Failed to serialize data".into()))?;

    let cipher = Aes256Gcm::new(&key.into());
    let nonce = Aes256Gcm::generate_nonce(&mut thread_rng());
    let ciphertext = cipher
        .encrypt(&nonce, json_str.as_bytes())
        .map_err(|_| NSEError::EncryptionFailed)?;

    let mut output = Vec::with_capacity(nonce.len() + ciphertext.len());
    output.extend_from_slice(&nonce);
    output.extend_from_slice(&ciphertext);

    let temp_path = format!("{file_path}.tmp");
    std::fs::write(&temp_path, &output).map_err(|e| NSEError::File(e.to_string()))?;

    if let Some(dir) = std::path::Path::new(file_path).parent()
        && let Ok(dir_file) = std::fs::File::open(dir)
    {
        let _ = dir_file.sync_all();
    }

    std::fs::rename(&temp_path, file_path).map_err(|e| NSEError::File(e.to_string()))?;

    Ok(())
}
