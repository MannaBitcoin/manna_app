use crate::boltz::error::BoltzError;
use crate::boltz::process_swap::{is_final_swap_state, process_swap};
use crate::boltz::swap_transaction::SwapTransactionType;
use crate::boltz::types::{Chain, ChainSwapDirection, ExtraSwapFee, PreImage, Swap, WebHook};
use crate::boltz::BoltzManager;
use crate::lnurl_util::LnurlUtil;
use crate::lwk::descriptor::Descriptor;
use crate::lwk::wallet::Wallet;
use crate::nse::receive_tx::WalletFile;
use crate::nse::util::{decrypt_file, encrypt_and_save_file};
use crate::nse::{NSEError, NotificationInfo};
use crate::util::{
    get_current_time, get_minimal_runtime, Crypto, LiquidWallet, MannaError, Network, WalletType,
};
use base64::prelude::BASE64_STANDARD;
use base64::Engine;
use boltz_client::boltz::RevSwapStates;
use boltz_client::util::secrets::{Preimage, SwapMasterKey};
use boltz_client::{Keypair, Secp256k1};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::ops::Div;
use std::path::PathBuf;
use tracing::instrument;

#[derive(Serialize, Deserialize)]
struct SwapFile {
    // swapId: swap data json
    pending_swaps: HashMap<String, Swap>,
    // swapId: completed swaps
    completed_swaps: HashMap<String, Swap>,
}

#[derive(Debug, Deserialize)]
struct BoltzStatusResponse {
    status: String,
    #[serde(rename = "failureReason", default)]
    failure_reason: Option<String>,
}

#[instrument(err, skip_all, fields(network))]
pub(super) fn fetch_and_store_lnurl_swaps(
    network: &Network,
    app_group_dir_path: String,
    enc_key: [u8; 32],
    jwt_tokens: [String; 3],
) -> Result<(), NSEError> {
    let wallet_file: WalletFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/wallets.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };

    if wallet_file.wallets.is_empty() {
        return Ok(());
    }

    let jwt_token = match network {
        Network::Mainnet => &jwt_tokens[0],
        Network::Testnet => &jwt_tokens[1],
        Network::Regtest => &jwt_tokens[2],
    };

    let fetched_swaps = LnurlUtil::fetch_lnurl_swaps(
        wallet_file.wallets,
        network,
        wallet_file.api_config,
        jwt_token,
        &wallet_file.device_id,
    )?;

    if fetched_swaps.is_empty() {
        return Ok(());
    }

    let mut swap_file: SwapFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/swaps.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };

    for swap in fetched_swaps {
        swap_file.pending_swaps.insert(swap.id.clone(), swap);
    }

    encrypt_and_save_file(
        &format!("{app_group_dir_path}/swaps.json.enc"),
        enc_key,
        &swap_file,
    )?;

    Ok(())
}

#[instrument(err(Display), skip_all, fields(network))]
pub(super) fn handle_swap_processing(
    network: &Network,
    app_group_dir_path: String,
    key: [u8; 32],
    jwt_tokens: [String; 3],
) -> Result<Vec<NotificationInfo>, NSEError> {
    let wallet_file: WalletFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/wallets.json.enc"), key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };
    let mut swap_file: SwapFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/swaps.json.enc"), key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };

    if swap_file.pending_swaps.is_empty() {
        return Ok(vec![]);
    }

    let mut ids: Vec<String> = swap_file
        .pending_swaps
        .values()
        .filter_map(|s| {
            if s.network == *network && !is_final_swap_state(s).1 {
                Some(s.id.clone())
            } else {
                None
            }
        })
        .collect();

    // This is hack to get response, boltz api only responds if we pass array with more than one id.
    if ids.len() == 1 {
        ids.push(ids[0].clone());
    }

    tracing::info!("fetching status for swap ids: {}", ids.join(", "));
    let mut req = ureq::get(format!(
        "{}/swap/status",
        wallet_file.get_boltz_url(network)
    ))
    .header("Content-Type", "application/json");
    for id in &ids {
        req = req.query("ids", id);
    }
    let mut res = req.call().map_err(|e| NSEError::Network(e.to_string()))?;
    let status_batch: HashMap<String, BoltzStatusResponse> = res
        .body_mut()
        .read_json()
        .map_err(|e| NSEError::Network(format!("json parsing failed:{e}")))?;

    let mut failed_chain_swaps: Vec<(String, bool)> = vec![];
    let mut newly_completed_swaps: Vec<Swap> = vec![];

    for (swap_id, status_data) in status_batch {
        // Skip if not in our pending
        if let Some(s) = swap_file.pending_swaps.get(&swap_id) {
            let mut swap = s.clone();
            let new_status = if swap.swap_status == "swap.refunded" {
                "swap.refunded".to_string()
            } else {
                status_data.status.clone()
            };

            if new_status != swap.swap_status {
                swap.swap_status = new_status;
            }
            if let Some(failure_reason) = status_data.failure_reason {
                swap.failure_reason.get_or_insert(failure_reason);
            }

            let boltz_manager = BoltzManager {
                api_config: wallet_file.api_config.clone(),
            };

            let res = get_minimal_runtime().block_on(process_swap(
                swap,
                &boltz_manager,
                app_group_dir_path.clone(),
                wallet_file.wallets.to_vec(),
                |_s| Box::pin(async move {}),
                |_s| Box::pin(async move {}),
                Some(wallet_file.device_id.clone()),
            ))?;
            let res = match res {
                Some(res) => res,
                None => {
                    tracing::info!("swap not processed:{}", swap_id);
                    return Ok(vec![]);
                }
            };

            // swap that requires user intervention
            if let Some(is_negotiable) = res.1 {
                failed_chain_swaps.push((swap_id.clone(), is_negotiable));
            }

            let (updated_swap, is_completed) = is_final_swap_state(&res.0);
            if is_completed {
                // TODO upsert the pool
                swap_file.pending_swaps.remove(&swap_id);
                if !swap_file.completed_swaps.contains_key(&swap_id) {
                    newly_completed_swaps.push(updated_swap.clone());
                }
                swap_file
                    .completed_swaps
                    .insert(updated_swap.id.clone(), updated_swap);
            } else {
                swap_file
                    .pending_swaps
                    .insert(swap_id.clone(), updated_swap);
            }
        }
    }

    encrypt_and_save_file(
        &format!("{app_group_dir_path}/swaps.json.enc"),
        key,
        &swap_file,
    )?;

    if !newly_completed_swaps.is_empty() {
        let supabase_config = wallet_file.api_config.get_supabase_config(network);
        let jwt_token = match network {
            Network::Mainnet => &jwt_tokens[0],
            Network::Testnet => &jwt_tokens[1],
            Network::Regtest => &jwt_tokens[2],
        };
        ureq::delete(format!(
            "https://{}.supabase.co/rest/v1/swap_webhook?swap_id=in.({})",
            supabase_config.project_ref,
            newly_completed_swaps
                .iter()
                .map(|s| s.id.clone())
                .collect::<Vec<_>>()
                .join(",")
        ))
        .header("apikey", &*supabase_config.api_key)
        .header("Authorization", &format!("Bearer {jwt_token}"))
        .call()
        .map_err(|e| {
            MannaError::from(
                "supabase delete pending lnurl swap".to_string(),
                e.to_string(),
            )
        })?;
    }

    if !failed_chain_swaps.is_empty() {
        let res = failed_chain_swaps
            .iter()
            .map(|s| NotificationInfo {
                title: Some(format!(
                    "Chain swap {} failed{}",
                    s.0,
                    if s.1 { ", but you can settle it." } else { "!" }
                )),
                body: Some("Open app to see specific details".to_string()),
                thread_id: None,
                sender_picture: None,
                payload: Some(
                    json!({
                        "type": "swap_detail",
                        "swapId": s.0,
                    })
                    .to_string(),
                ),
            })
            .collect::<Vec<_>>();
        return Ok(res);
    }

    if !newly_completed_swaps.is_empty() {
        let build_amount_text_with_style = |amount: u64| -> String {
            match wallet_file.bitcoin_display_style.unwrap_or(0) {
                1 => format!("{} sats", amount),
                2 => format!("{:.6} BTC", amount.div(100000000)),
                _ => format!("₿ {}", amount),
            }
        };

        let res = newly_completed_swaps
            .iter()
            .filter_map(|s| {
                // take only the receiving completed swaps for notification
                if s.reverse.is_some()
                    || s.chain
                        .as_ref()
                        .map(|c| c.direction == ChainSwapDirection::BtcToLbtc)
                        .is_some()
                {
                    let tx = s
                        .transactions
                        .iter()
                        .find(|tx| tx.is_user && tx.tx_type == SwapTransactionType::Claim);
                    let receiver_wallet_name = wallet_file
                        .wallets
                        .iter()
                        .find(|w| w.uuid == s.wallet_id)
                        .map(|t| t.wallet_name.clone())
                        .flatten();

                    Some(NotificationInfo {
                        title: Some(
                            format!(
                                "Received {}",
                                build_amount_text_with_style(s.receive_amount)
                            ) + &receiver_wallet_name
                                .map(|name| format!(" in {}", name))
                                .unwrap_or_default()
                                + if s.network == Network::Regtest {
                                    " (MannaNet)"
                                } else {
                                    ""
                                },
                        ),
                        body: s.note.clone().or(Some("Tap to view".to_string())),
                        thread_id: None,
                        sender_picture: None,
                        payload: tx.map(|tx| {
                            json!({
                                "type": "received_tx",
                                "txId": tx.tx_id.to_string(),
                                "receiverId": s.wallet_id,
                                "amount": s.receive_amount,
                            })
                            .to_string()
                        }),
                    })
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();

        return Ok(res);
    }

    Ok(vec![])
}

#[derive(Serialize, Deserialize)]
struct Bolt12File {
    offers: Option<Vec<Value>>,
}

#[instrument(err, skip_all, fields(network))]
pub(super) fn handle_bolt12_invoice_request(
    network: &Network,
    notification_data: Value,
    app_group_dir_path: String,
    enc_key: [u8; 32],
    jwt_tokens: [String; 3],
) -> Result<Vec<NotificationInfo>, NSEError> {
    let wallet_file: WalletFile = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/wallets.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };
    let bolt12_file: Bolt12File = {
        let raw = decrypt_file(&format!("{app_group_dir_path}/bolt12.json.enc"), enc_key)?;
        serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
    };
    let Some(offers) = bolt12_file.offers else {
        return Ok(vec![]);
    };
    let offer_param = notification_data["offer"]
        .as_str()
        .ok_or(NSEError::InvalidData("Missing offer".to_string()))?
        .to_string();
    let invoice_request_hex_param = notification_data["invoiceRequestHex"]
        .as_str()
        .ok_or(NSEError::InvalidData(
            "Missing invoiceRequestHex".to_string(),
        ))?
        .to_string();
    let request_id_param = notification_data["requestId"]
        .as_str()
        .ok_or(NSEError::InvalidData("Missing requestId".to_string()))?
        .to_string();
    let jwt_token = match network {
        Network::Mainnet => &jwt_tokens[0],
        Network::Testnet => &jwt_tokens[1],
        Network::Regtest => &jwt_tokens[2],
    };

    let inner = || -> Result<(String, Swap, String), NSEError> {
        // matching offer search
        let offer_struct = offers.iter().find(|e| {
            if let Some(offer_str) = e["offer"].as_str() {
                offer_str == offer_param
            } else {
                false
            }
        });

        let Some(offer_struct) = offer_struct else {
            return Err(NSEError::InvalidData("Missing signingKey".to_string()));
        };

        // wallet
        let wallet_id = offer_struct["walletId"]
            .as_str()
            .ok_or(NSEError::InvalidData("Missing walletId".to_string()))?
            .to_string();
        let wallet_type_index = offer_struct["walletType"]
            .as_u64()
            .ok_or(NSEError::InvalidData("Missing walletType".to_string()))?;
        let wallet_type = match wallet_type_index {
            0 => WalletType::Full,
            1 => WalletType::WatchOnly,
            _ => unreachable!("Invalid variant for WalletType: {}", wallet_type_index),
        };
        let wallet = wallet_file
            .wallets
            .iter()
            .find(|wallet| wallet.uuid == wallet_id && wallet.wallet_type == wallet_type);
        let Some(wallet) = wallet else {
            return Err(NSEError::InvalidData("Missing wallet".to_string()));
        };

        // signing key
        let signing_key_hex_str = offer_struct["signingKey"]["secretKey"]
            .as_str()
            .ok_or(NSEError::InvalidData("Missing signingKey".to_string()))?
            .to_string();
        let secp = Secp256k1::new();

        let signing_key = Keypair::from_seckey_slice(
            &secp,
            &hex::decode(signing_key_hex_str).map_err(|_| {
                NSEError::InvalidData("Failed to parse signing key hex".to_string())
            })?,
        )
        .map_err(|e| NSEError::InvalidData(format!("Failed to create signingKey:{e}")))?;

        // Swap index
        let supabase_config = wallet_file.api_config.get_supabase_config(network);

        let mut swap_index_res = ureq::get(&format!(
            "https://{}.supabase.co/rest/v1/wallets?select=swap_index&uuid=eq.{}&limit=1",
            supabase_config.project_ref, wallet.uuid
        ))
        .header("apikey", &*supabase_config.api_key)
        .header("Authorization", &format!("Bearer {jwt_token}"))
        .call()
        .map_err(|e| NSEError::Network(format!("swap index :{e}")))?;
        if swap_index_res.status() == 401 {
            return Err(NSEError::Jwt());
        }
        let json_array: Vec<Value> = swap_index_res
            .body_mut()
            .read_json()
            .map_err(|e| NSEError::Network(format!("swap index: json parsing failed:{e}")))?;

        let Some(swap_index) = json_array
            .first()
            .map(|item| item["swap_index"].as_u64())
            .flatten()
        else {
            return Err(NSEError::Network("Missing swap index".to_string()));
        };

        let swap_master_key =
            SwapMasterKey::from_mnemonic(&wallet.swap_mnemonic, None, (*network).into())
                .map_err(|e| NSEError::Swap(e.to_string()))?;
        let claim_keypair = swap_master_key
            .derive_swapkey(swap_index)
            .map_err(|e| NSEError::Swap(e.to_string()))?;
        let preimage: PreImage = Preimage::from_swap_key(&claim_keypair).into();

        // liquid address

        let mut lwk_path = PathBuf::from(app_group_dir_path.clone());
        lwk_path.push("lwk");
        let lwk_path = lwk_path
            .to_str()
            .ok_or(NSEError::InvalidData("Invalid LWK path".to_string()))?;
        let wollet = wallet
            .init(lwk_path.to_string(), *network)
            .map_err(|e| NSEError::LWK(e.msg))?;
        let address_res = wollet
            .address_last_unused()
            .map_err(|e| NSEError::LWK(e.msg))?;
        let liquid_address = address_res.standard;

        let (bolt12_invoice, address_signature) = get_minimal_runtime()
            .block_on(
                BoltzManager {
                    api_config: wallet_file.api_config.clone(),
                }
                .create_bol12_invoice(
                    offer_param,
                    invoice_request_hex_param,
                    signing_key.into(),
                    *network,
                    preimage.sha256,
                    liquid_address.clone(),
                ),
            )
            .map_err(NSEError::from)?;

        // reverse swap fee fetching
        let mut reverse_fee_res = ureq::get(&format!(
            "https://{}.supabase.co/rest/v1/settings?select=value&key=eq.app_ln_lbtc_swap_fee&limit=1",
            supabase_config.project_ref
        ))
            .header("apikey", &*supabase_config.api_key)
            .header("Authorization", &format!("Bearer {jwt_token}"))
            .call()
            .map_err(|e| NSEError::Network(format!("ln_lbtc fee :{e}")))?;
        if reverse_fee_res.status() == 401 {
            return Err(NSEError::Jwt());
        }
        let json_array: Vec<Value> = reverse_fee_res
            .body_mut()
            .read_json()
            .map_err(|e| NSEError::Network(format!("ln_lbtc fee: json parsing failed:{e}")))?;

        let Some(ln_lbtc_swap_fee) = json_array
            .first()
            .map(|item| item["value"].as_str())
            .flatten()
        else {
            return Err(NSEError::Network("Missing ln_lbtc_swap_fee".to_string()));
        };

        // Create reverse swap
        let webhook = if !wallet_file
            .api_config
            .get_config(network)
            .server_url
            .is_empty()
        {
            Some(WebHook {
                url: wallet_file
                    .api_config
                    .get_config(network)
                    .get_server_api_endpoint("webhook/mobile/swap"),
                statuses: Some(
                    [
                        RevSwapStates::TransactionMempool.to_string(),
                        RevSwapStates::TransactionConfirmed.to_string(),
                        RevSwapStates::TransactionFailed.to_string(),
                        RevSwapStates::TransactionRefunded.to_string(),
                    ]
                    .to_vec(),
                ),
            })
        } else {
            None
        };
        let reverse_swap_fee: f32 = ln_lbtc_swap_fee
            .parse()
            .map_err(|e| NSEError::Network(format!("can't parse reverse swap fee:{e}")))?;
        let reverse_swap_res = get_minimal_runtime().block_on(
            BoltzManager {
                api_config: wallet_file.api_config.clone(),
            }
            .new_reverse(
                wallet.clone(),
                *network,
                Chain::Liquid,
                Some(liquid_address.clone()),
                Some(address_signature),
                None,
                swap_index,
                None,
                Some(ExtraSwapFee {
                    id: "app_ln_lbtc".to_string(),
                    percentage: reverse_swap_fee,
                }),
                webhook,
                Some(bolt12_invoice.clone()),
            ),
        );
        let reverse_swap = match reverse_swap_res {
            Ok(res) => res,
            Err(e) => {
                if e.message.contains("already")
                    && e.message.contains("exists")
                    && e.message.contains("preimage")
                {
                    let mut payload = Map::new();
                    payload.insert("swap_index".to_string(), json!(swap_index + 1));
                    for (key, value) in build_pool(network, wallet, &wollet, swap_index)? {
                        payload.insert(key, value);
                    }
                    upsert_wallet(
                        wallet,
                        payload,
                        wallet_file
                            .api_config
                            .get_config(network)
                            .get_server_api_endpoint("upsertWallets"),
                        jwt_token.clone(),
                        wallet_file.device_id.clone(),
                    )?;
                }
                return Err(e.into());
            }
        };

        // save the swap in pending swap list
        {
            let mut swap_file: SwapFile = {
                let raw = decrypt_file(&format!("{app_group_dir_path}/swaps.json.enc"), enc_key)?;
                serde_json::from_value(raw).map_err(|e| NSEError::InvalidFileData(e.to_string()))?
            };
            swap_file
                .pending_swaps
                .insert(reverse_swap.id.clone(), reverse_swap.clone());

            encrypt_and_save_file(
                &format!("{app_group_dir_path}/swaps.json.enc"),
                enc_key,
                &swap_file,
            )?;
        }

        let mut payload = Map::new();
        payload.insert("swap_index".to_string(), json!(swap_index + 1));
        for (key, value) in build_pool(network, wallet, &wollet, swap_index)? {
            payload.insert(key, value);
        }
        upsert_wallet(
            wallet,
            payload,
            wallet_file
                .api_config
                .get_config(network)
                .get_server_api_endpoint("upsertWallets"),
            jwt_token.clone(),
            wallet_file.device_id.clone(),
        )?;

        Ok((wallet_id, reverse_swap, bolt12_invoice))
    };

    let (payload, notification_body, err) = match inner() {
        Ok((wallet_id, reverse_swap, bolt12_invoice)) => (
            json!({
                "requestId": request_id_param,
                "invoice": bolt12_invoice,
                "walletId": wallet_id,
                "deviceId": wallet_file.device_id,
                "swapId": reverse_swap.id,
            }),
            Some(format!(
                "{}...{} ({})",
                bolt12_invoice[..5].to_string(),
                bolt12_invoice[bolt12_invoice.len() - 5..].to_string(),
                reverse_swap.id
            )),
            None,
        ),
        Err(err) => (
            json!({
                "requestId": request_id_param,
                "error": "Invoice generation failed!"
                // "error": err.to_string()
            }),
            None,
            Some(err),
        ),
    };

    match ureq::post(
        wallet_file
            .api_config
            .get_config(network)
            .get_server_api_endpoint("bolt12InvoiceReady"),
    )
    .config()
    .http_status_as_error(false)
    .build()
    .header("Authorization", &format!("Bearer {jwt_token}"))
    .send_json(payload)
    {
        Ok(mut res) => {
            if let Some(e) = err {
                return Err(e);
            }
            if res.status() == 200 {
                return Ok(vec![NotificationInfo {
                    title: Some("Created invoice on bolt12 request".to_string()),
                    body: notification_body,
                    thread_id: Some("bolt12InvReq".to_string()),
                    sender_picture: None,
                    payload: None,
                }]);
            } else if res.status() == 401 {
                return Err(NSEError::Jwt());
            } else {
                match res.body_mut().read_to_string() {
                    Ok(r) => {
                        tracing::error!("bolt12InvoiceReady response: {}-{r}", res.status());
                    }
                    Err(_) => {
                        tracing::error!("bolt12InvoiceReady status: {}", res.status());
                    }
                }
            }
        }
        Err(e) => {
            return Err(NSEError::Network(format!("bolt12InvoiceReady: {e}")));
        }
    }

    Ok(vec![])
}

#[instrument(err, skip_all, fields(network, wallet_id = wallet.uuid, swap_index))]
fn build_pool(
    network: &Network,
    wallet: &LiquidWallet,
    wollet: &Wallet,
    swap_index: u64,
) -> Result<Map<String, Value>, NSEError> {
    let mut last_used_index: u32 = 0;
    let mut address_pool = HashMap::<u32, String>::new();
    for _ in 0..50 {
        if last_used_index == 0 {
            let a = wollet
                .address_last_unused()
                .map_err(|e| BoltzError::new("LWK".to_string(), e.msg))?;
            if let Some(index) = a.index {
                last_used_index = index;
                address_pool.insert(index, a.confidential);
            }
        } else {
            last_used_index += 1;
            let a = wollet
                .address(last_used_index)
                .map_err(|e| BoltzError::new("LWK".to_string(), e.msg))?;
            if let Some(index) = a.index {
                address_pool.insert(index, a.confidential);
            }
        }
    }

    let mut swap_index = swap_index;
    let lnurl_indices: Vec<u64> = (0..15)
        .map(|_| {
            let current = swap_index;
            swap_index += 1;
            current
        })
        .collect();
    if lnurl_indices.len() > address_pool.len() {
        return Err(NSEError::InvalidData(
            "address pool and lnurl pool panic".to_string(),
        ));
    }
    let addresses: Vec<(u64, String)> = address_pool
        .clone()
        .into_iter()
        .take(lnurl_indices.len())
        .map(|x| (x.0 as u64, x.1))
        .collect();
    let lnurl_pool: Vec<_> = Crypto::generate_lnurl_pool(
        &*wallet.swap_mnemonic,
        network.clone(),
        lnurl_indices,
        Some(addresses),
    )?
    .into_iter()
    .map(|e| {
        e.address.map(|address| {
            json!({
              "i": e.index,
              "addr": {'i': address.index, 'a': address.address, 's': address.signature},
              "pih": e.preimage.sha256,
              "cpk": BASE64_STANDARD.encode(e.claim_key.public_key),
            })
        })
    })
    .flatten()
    .collect();

    let mut payload = Map::new();
    payload.insert(
        "address_pool".to_string(),
        json!(
            address_pool
                .into_iter()
                .map(|e| json!({"i": e.0, "a": e.1}))
                .collect::<Vec<_>>()
        ),
    );
    payload.insert("lnurl_pool".to_string(), json!(lnurl_pool));

    Ok(payload)
}

#[instrument(err, skip_all, fields(network, wallet_id = wallet.uuid, data, endpoint))]
fn upsert_wallet(
    wallet: &LiquidWallet,
    data: Map<String, Value>,
    endpoint: String,
    jwt_token: String,
    device_id: String,
) -> Result<(), NSEError> {
    let Some((xpub, _)) =
        Descriptor::extract_xpub(&*wallet.descriptor).map_err(|e| NSEError::LWK(e.msg))?
    else {
        return Err(NSEError::InvalidData("Missing xpub".to_string()));
    };
    let mut payload = data;
    payload.insert("uuid".to_string(), json!(wallet.uuid));
    payload.insert("wallet_xpub".to_string(), json!(xpub));
    payload.insert("timestamp".to_string(), json!(get_current_time()));

    let payload = if let Some(ref priv_key_hex) = wallet.upsert_derivation_private_key_hex {
        let priv_key_bytes = hex::decode(priv_key_hex).map_err(|e| {
            NSEError::InvalidData(format!(
                "invalid hex - upsert derivation private key: {}",
                e
            ))
        })?;

        payload.sort_keys();
        let signature = Crypto::secp256k1_sign(
            priv_key_bytes,
            serde_json::to_string(&payload)
                .map_err(|e| NSEError::InvalidData(e.to_string()))?
                .as_bytes()
                .to_vec(),
            false,
            Some(true),
        )?;
        let signature_hex = hex::encode(signature);

        payload.insert("signature".to_string(), json!(signature_hex));
        Value::Object(payload)
    } else {
        Value::Object(payload)
    };

    let now = Utc::now().to_rfc3339();
    let upsert_payload = match wallet.wallet_type {
        WalletType::Full => json!({
            "walletData": [payload],
            "watchOnlyWalletData": [],
            "device_id": device_id,
            "last_active_at": now
        }),
        WalletType::WatchOnly => json!({
            "walletData": [],
            "watchOnlyWalletData": [payload],
            "device_id": device_id,
            "last_active_at": now
        }),
    };

    match ureq::post(endpoint)
        .config()
        .http_status_as_error(false)
        .build()
        .header("Authorization", &format!("Bearer {jwt_token}"))
        .send_json(upsert_payload)
    {
        Ok(mut res) => {
            if res.status() == 200 {
                Ok(())
            } else if res.status() == 401 {
                Err(NSEError::Jwt())
            } else {
                match res.body_mut().read_to_string() {
                    Ok(r) => {
                        tracing::error!("Upsert response: {}-{r}", res.status());
                    }
                    Err(_) => {
                        tracing::error!("Upsert status: {}", res.status());
                    }
                }
                Err(NSEError::Network("Upsert wallet".to_string()))
            }
        }
        Err(e) => Err(NSEError::Network(format!("Upsert wallet: {e}"))),
    }
}
