use crate::nse::receive_tx::WalletFile;
use crate::nse::util::{decrypt_file, encrypt_and_save_file};
use crate::nse::{NSEError, NotificationInfo};
use crate::util::{Crypto, Network, WalletType};
use base64::{Engine, prelude::BASE64_STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::str::FromStr;
use tracing::instrument;
use uuid::Uuid;

#[derive(Serialize, Deserialize, Clone)]
struct Contact {
    uuid: String,
    wallet_id: String,
    wallet_type: WalletType,
    name: String,
    chat_pub_key_base64: String,
    picture: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct ContactFile {
    wallet_chat_keys: Option<HashMap<String, String>>,
    contacts_data: Option<Vec<Vec<Value>>>,
}

impl ContactFile {
    fn get_contacts(&self) -> Vec<Contact> {
        let Some(data) = &self.contacts_data else {
            return vec![];
        };

        data.into_iter()
            .filter_map(|row| {
                let uuid = row.get(0)?.as_str()?.to_string();
                let wallet_id = row.get(1)?.as_str()?.to_string();
                let wallet_type = match row.get(2)?.as_u64()? {
                    1 => WalletType::WatchOnly,
                    _ => WalletType::Full,
                };
                let name = row.get(3)?.as_str()?.to_string();
                let chat_pub_key_base64 = row.get(4)?.as_str()?.to_string();
                let picture = row.get(5).and_then(|v| v.as_str()).and_then(|s| {
                    if s.is_empty() {
                        None
                    } else {
                        Some(s.to_string())
                    }
                });

                Some(Contact {
                    uuid,
                    wallet_id,
                    wallet_type,
                    name,
                    chat_pub_key_base64,
                    picture,
                })
            })
            .collect()
    }

    fn add_contact(&mut self, contact: Contact) {
        let row = vec![
            Value::String(contact.uuid),
            Value::String(contact.wallet_id),
            Value::Number(
                match contact.wallet_type {
                    WalletType::Full => 0,
                    WalletType::WatchOnly => 1,
                }
                .into(),
            ),
            Value::String(contact.name),
            Value::String(contact.chat_pub_key_base64),
            contact.picture.map(Value::String).unwrap_or(Value::Null),
        ];

        self.contacts_data.get_or_insert_with(Vec::new).push(row);
    }
}

#[instrument(err, skip_all, fields(network))]
pub(crate) fn handle_chat_notification(
    network: &Network,
    notification_data: Value,
    app_group_dir_path: String,
    enc_key: [u8; 32],
    jwt_tokens: [String; 3],
) -> Result<NotificationInfo, NSEError> {
    let message_log_uuid = notification_data["uuid"]
        .as_str()
        .ok_or(NSEError::InvalidData(
            "Missing message log uuid".to_string(),
        ))?;
    let sender_id = notification_data["senderId"]
        .as_str()
        .ok_or(NSEError::InvalidData(
            "Missing message log sender id".to_string(),
        ))?;
    let receiver_id = notification_data["receiverId"]
        .as_str()
        .ok_or(NSEError::InvalidData(
            "Missing message log receiver id".to_string(),
        ))?;

    if receiver_id.is_empty() || sender_id.is_empty() || message_log_uuid.is_empty() {
        return Err(NSEError::InvalidData(
            "Missing message log metadata".to_string(),
        ));
    }

    let wallet_file: WalletFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/wallets.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };
    let supabase_config = wallet_file.api_config.get_supabase_config(network);
    let jwt_token = match network {
        Network::Mainnet => &jwt_tokens[0],
        Network::Testnet => &jwt_tokens[1],
        Network::Regtest => &jwt_tokens[2],
    };

    // let mut message_data: Option<String> = None;
    let data = notification_data["data"].as_str();
    let message_hex_str: String = if let Some(data) = data {
        data.to_string()
    } else {
        // fetch message logs from database
        let url = format!(
            "https://{}.supabase.co/rest/v1/message_log?select=data&uuid=eq.{message_log_uuid}",
            supabase_config.project_ref
        );
        let mut response = ureq::get(&url)
            .header("apikey", &*supabase_config.api_key)
            .header("Authorization", &format!("Bearer {jwt_token}"))
            .header("Accept-Profile", "chat")
            .header("Content-Profile", "chat")
            .call()
            .map_err(|e| NSEError::Network(e.to_string()))?;

        if response.status() == 401 {
            return Err(NSEError::Jwt());
        }

        let json_array: Vec<Value> = response
            .body_mut()
            .read_json()
            .map_err(|e| NSEError::Network(format!("json parsing failed :{e}")))?;

        json_array
            .first()
            .ok_or(NSEError::Network("can't get message data".to_string()))?
            .get("data")
            .ok_or(NSEError::Network("can't get message data".to_string()))?
            .as_str()
            .ok_or(NSEError::Network("can't get message data".to_string()))?
            .to_string()
    };

    let message_hex = hex::decode(
        message_hex_str
            .strip_prefix("\\x")
            .unwrap_or(&*message_hex_str),
    )
    .map_err(|e| NSEError::InvalidData(e.to_string()))?;

    // get sender contact
    let mut contact_file: ContactFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/chat.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };

    let receiver_wallet_chat_priv_key_base64: String = {
        contact_file
            .wallet_chat_keys
            .as_ref()
            .and_then(|map| map.get(receiver_id))
            .ok_or(NSEError::InvalidData(
                "Missing wallet_chat_keys".to_string(),
            ))?
            .clone()
    };

    // Try to find sender in local contacts
    let contacts = contact_file.get_contacts();
    let sender_contact = contacts.iter().find(|c| c.uuid == sender_id);
    let mut fetched_contact: Option<Contact> = None;

    if sender_contact.is_none() {
        // Fetch from Supabase
        let url = format!(
            "https://{}.supabase.co/rest/v1/wallets?select=uuid,user_name,picture,wallet_chat_keys(pubkey)&uuid=eq.{sender_id}",
            supabase_config.project_ref
        );

        let mut response = ureq::get(&url)
            .header("apikey", &*supabase_config.api_key)
            .header("Authorization", &format!("Bearer {jwt_token}"))
            .call()
            .map_err(|e| NSEError::Network(e.to_string()))?;

        if response.status() == 401 {
            return Err(NSEError::Jwt());
        }

        let json_array: Vec<Value> = response
            .body_mut()
            .read_json()
            .map_err(|e| NSEError::Network(format!("json parsing failed: {e}")))?;

        if let Some(item) = json_array.first() {
            let new_contact = Contact {
                uuid: item["uuid"].as_str().unwrap_or_default().to_string(),
                wallet_id: receiver_id.to_string().clone(),
                wallet_type: WalletType::Full,
                name: item["user_name"].as_str().unwrap_or_default().to_string(),
                chat_pub_key_base64: item["wallet_chat_keys"]["pubkey"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string(),
                picture: item["picture"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
            };

            contact_file.add_contact(new_contact.clone());
            encrypt_and_save_file(
                &format!("{app_group_dir_path}/chat.json.enc"),
                enc_key,
                &contact_file,
            )?;

            fetched_contact = Some(new_contact);
        }
    }

    let contact = sender_contact
        .or(fetched_contact.as_ref())
        .ok_or(NSEError::InvalidData("Missing sender contact".to_string()))?;

    let sender_pubkey = BASE64_STANDARD
        .decode(&contact.chat_pub_key_base64)
        .map_err(|e| NSEError::Base64Decode(e.to_string()))?;

    let receiver_privkey = BASE64_STANDARD
        .decode(&receiver_wallet_chat_priv_key_base64)
        .map_err(|e| NSEError::Base64Decode(e.to_string()))?;

    // decrypt message data
    let message_str = Crypto::decrypt_chat_message_as_receiver(
        receiver_privkey.clone(),
        sender_pubkey.clone(),
        message_hex,
    )
    .map_err(|e| NSEError::MessageDecryptionFailed(format!("{:?} : {}", e.kind, e.msg)))?;
    let message_data: Value =
        serde_json::from_str(&message_str).map_err(|e| NSEError::InvalidData(e.to_string()))?;

    let message_id = message_data["id"].as_str().unwrap_or_default();
    let message_content = message_data["content"].as_str().unwrap_or_default();
    let message_type = message_data["type"].as_str().unwrap_or_default();

    // Update message status on server
    let received_receipt_bytes =
        Crypto::encrypt_chat_message(receiver_privkey, sender_pubkey, message_id.to_string())
            .map_err(|e| NSEError::MessageDecryptionFailed(format!("{:?} : {}", e.kind, e.msg)))?;
    let received_receipt_hex = hex::encode(received_receipt_bytes);
    let uuid_namespace = Uuid::from_str("7d09e47f-b6b2-4e8c-8b8b-42769a3885b7")
        .map_err(|_| NSEError::Manna("Failed to parse UUID".to_string()))?;
    let uuid = Uuid::new_v5(&uuid_namespace, format!("{message_id}received").as_bytes());

    let receipt_url = format!(
        "https://{}.supabase.co/rest/v1/message_log",
        supabase_config.project_ref
    );
    ureq::post(receipt_url)
        .header("apikey", &*supabase_config.api_key)
        .header("Authorization", &format!("Bearer {jwt_token}"))
        .header("Prefer", "resolution=ignore-duplicates")
        .header("Accept-Profile", "chat")
        .header("Content-Profile", "chat")
        .send_json(json!({
            "uuid": uuid.to_string(),
            "sender_id": receiver_id.to_string(),
            "receiver_id": sender_id.to_string(),
            "event_type": 1,
            "data":format!("\\x{received_receipt_hex}"),
        }))
        .map_err(|e| NSEError::Network(format!("Failed to update message status:{e}")))?;

    Ok(NotificationInfo {
        title: Some(contact.name.clone()),
        body: Some(
            if message_type == "text" {
                message_content
            } else {
                "New message"
            }
            .to_string(),
        ),
        thread_id: Some(contact.uuid.clone()),
        sender_picture: contact.picture.clone(),
        payload: Some(
            json!({
                "type": "new_message_chat",
                "receiverId": receiver_id,
                "senderId": contact.uuid,
            })
            .to_string(),
        ),
    })
}
