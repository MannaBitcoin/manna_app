use crate::nse::util::decrypt_file;
use crate::nse::{NSEError, NotificationInfo};
use crate::types::{ApiConfig, LiquidWallet, Network};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tracing::instrument;

#[derive(Serialize, Deserialize)]
pub(super) struct WalletFile {
    pub(super) wallets: Vec<LiquidWallet>,
    pub(super) api_config: ApiConfig,
    pub(super) device_id: String,
    pub(super) bitcoin_display_style: Option<u8>,
}

#[instrument(err, skip_all, fields(network))]
pub(crate) fn handle_receive_tx_notification(
    network: &Network,
    notification_data: Value,
    app_group_dir_path: String,
    enc_key: [u8; 32],
) -> Result<NotificationInfo, NSEError> {
    let receiver_uuid = notification_data["receiverId"]
        .as_str()
        .ok_or(NSEError::InvalidData("Missing receiver uuid".to_string()))?
        .to_string();

    let tx_id = notification_data["txId"]
        .as_str()
        .ok_or(NSEError::InvalidData("Missing txId".to_string()))?
        .to_string();

    let amount = notification_data["amount"]
        .as_str()
        .ok_or(NSEError::InvalidData("Missing txId".to_string()))?
        .to_string();

    if receiver_uuid.is_empty() || tx_id.is_empty() || amount.is_empty() {
        return Err(NSEError::InvalidData("Missing data".to_string()));
    }

    let wallet_file: WalletFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/wallets.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };

    let receiver_wallet = wallet_file
        .wallets
        .iter()
        .find(|w| w.uuid == receiver_uuid)
        .ok_or(NSEError::InvalidData("Missing wallet".to_string()))?;
    // sync wallet: optional
    // {
    //     let mut wollet = receiver_wallet
    //         .init(app_group_dir_path, *network)
    //         .map_err(|e| NSEError::LWK(e.msg.to_string()))?;
    //
    //     let electrum_url = wallet_file
    //         .api_config
    //         .get_electrum_url(network, &Chain::Liquid)?;
    //     let mut electrum_client: ElectrumClient =
    //         ElectrumClient::new(&electrum_url).map_err(|e| NSEError::LWK(e.to_string()))?;
    //
    //     full_scan_with_electrum_client(&mut wollet, &mut electrum_client)
    //         .map_err(|e| NSEError::LWK(e.to_string()))?;
    // thread::sleep(Duration::from_millis(1000));
    // }

    let original_title = notification_data["title"]
        .as_str()
        .ok_or(NSEError::InvalidData("Missing title".to_string()))?;

    let mut new_title: Option<String> = Some(original_title.to_string());
    if let Some(bitcoin_display_style) = wallet_file.bitcoin_display_style {
        let re =
            Regex::new(r"₿\s?(\d+\.?\d*)").map_err(|e| NSEError::InvalidData(e.to_string()))?;

        if let Some(caps) = re.captures(original_title) {
            let amount = caps[1].parse::<f64>().unwrap_or(0.0);
            let new_currency = match bitcoin_display_style {
                1 => format!("{} sats", amount),
                2 => format!("{:.6} BTC", amount / 100000000.0),
                _ => format!("₿ {}", amount),
            };
            new_title = Some(re.replace(original_title, new_currency).to_string());
        };
    }

    if let Some(name) = &receiver_wallet.wallet_name {
        new_title = new_title.map(|title| format!("{title} in {name}"));
    }
    new_title = new_title.map(|title| {
        title
            + if *network == Network::Regtest {
                " (MannaNet)"
            } else {
                ""
            }
    });

    Ok(NotificationInfo {
        title: new_title,
        body: None,
        thread_id: None,
        sender_picture: None,
        payload: Some(
            json!({
                "type": "received_tx",
                "txId": tx_id,
                "receiverId": receiver_uuid,
                "amount": amount,
            })
            .to_string(),
        ),
    })
}
