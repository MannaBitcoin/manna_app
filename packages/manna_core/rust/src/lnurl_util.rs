use crate::boltz::swap_transaction::{SwapTransaction, SwapTransactionType};
use crate::boltz::types::{ApiConfig, Chain, ReverseResponse, ReverseSwap, Swap};
use crate::util::{Crypto, LiquidWallet, LnurlPoolEntry, MannaError, Network, get_minimal_runtime};
use boltz_client::lnurl::get_derivation_path;
use boltz_client::lnurl::lnurl::LnUrl;
use boltz_client::reqwest::Url;
use chrono::DateTime;
use flutter_rust_bridge::frb;
use serde_json::Value;
use std::collections::HashMap;
use std::str::FromStr;

pub struct LnurlUtil {}

impl LnurlUtil {
    /// parses lnurl URI or bech32 string to URI
    #[frb(sync)]
    pub fn decode(lnurl: &str) -> Result<String, MannaError> {
        Ok(LnUrl::from_str(lnurl)
            .map_err(|e| MannaError::from("LNURL".to_string(), e.to_string()))?
            .url)
    }

    pub fn get_signing_derivation_path(
        hashing_key: [u8; 32],
        lnurl: &str,
    ) -> Result<String, MannaError> {
        Ok(get_derivation_path(
            hashing_key,
            &Url::parse(lnurl)
                .map_err(|e| MannaError::from("Parsing".to_string(), e.to_string()))?,
        )
        .map_err(|e| MannaError::from("LNURL".to_string(), e.to_string()))?
        .to_string())
    }

    /// fetches pending lnurl swaps from database and returns it after decryption
    pub fn fetch_lnurl_swaps(
        liquid_wallets: Vec<LiquidWallet>,
        network: &Network,
        api_config: ApiConfig,
        jwt_token: &str,
        device_id: &str,
    ) -> Result<Vec<Swap>, MannaError> {
        if liquid_wallets.is_empty() {
            return Ok(Vec::new());
        }

        let supabase_config = api_config.get_supabase_config(network);
        let url = format!(
            "https://{}.supabase.co/rest/v1/pending_lnurl_swaps?wallet_id=in.({})&or=(device_id.is.null,device_id.eq.{})",
            supabase_config.project_ref,
            liquid_wallets
                .iter()
                .map(|w| w.uuid.clone())
                .collect::<Vec<_>>()
                .join(","),
            device_id
        );
        let mut resp = ureq::get(&url)
            .header("apikey", &*supabase_config.api_key)
            .header("Authorization", &format!("Bearer {jwt_token}"))
            .call()
            .map_err(|e| MannaError::from("supabase".to_string(), e.to_string()))?;

        if resp.status() == 401 {
            return Err(MannaError::from(
                "supabase".to_string(),
                "401 Unauthorised, while fetching pending lnurl swaps".to_string(),
            ));
        }

        let rows: Vec<Value> = resp
            .body_mut()
            .read_json()
            .map_err(|e| MannaError::from("Supabase serde".to_string(), e.to_string()))?;

        if rows.is_empty() {
            return Ok(Vec::new());
        }

        // Group rows by wallet_id → index → row
        let mut lnurl_swaps_by_wallet: HashMap<String, HashMap<u64, Value>> = HashMap::new();

        for row in rows {
            let wallet_id = row["wallet_id"]
                .as_str()
                .ok_or_else(|| MannaError::new("missing wallet_id".to_string()))?
                .to_string();

            let index = row["swap_index"]
                .as_u64()
                .ok_or_else(|| MannaError::new("missing swap index".to_string()))?;

            lnurl_swaps_by_wallet
                .entry(wallet_id)
                .or_default()
                .insert(index, row);
        }

        let mut fetched_swaps = Vec::new();

        for (wallet_id, swaps_by_index) in lnurl_swaps_by_wallet {
            let wallets = liquid_wallets
                .iter()
                .filter(|w| w.uuid == wallet_id)
                .collect::<Vec<_>>();
            if wallets.is_empty() {
                continue;
            }

            for (index, row) in &swaps_by_index {
                let swap_data_hex = row["swap_data"]
                    .as_str()
                    .ok_or_else(|| MannaError::new("missing swap_data".to_string()))?;
                let server_data = row["server_data"].as_object();

                // skip "0x" prefix safely
                let ciphertext_swap =
                    hex::decode(swap_data_hex.strip_prefix("\\x").unwrap_or(swap_data_hex))
                        .map_err(|e| MannaError::from("swap cipher".to_string(), e.to_string()))?;

                let wrapped_key_hex = row["wrapped_k"]
                    .as_str()
                    .ok_or_else(|| MannaError::new("missing wrapped_k".to_string()))?;

                let ciphertext_key = hex::decode(
                    wrapped_key_hex
                        .strip_prefix("\\x")
                        .unwrap_or(wrapped_key_hex),
                )
                .map_err(|e| MannaError::from("key cipher".to_string(), e.to_string()))?;

                // Iterate through wallets to find the one that can decrypt this swap
                for wallet in &wallets {
                    let Ok(pool_vec) = Crypto::generate_lnurl_pool(
                        &wallet.swap_mnemonic,
                        *network,
                        swaps_by_index.keys().copied().collect(),
                        None,
                    ) else {
                        continue;
                    };
                    let pool: HashMap<u64, LnurlPoolEntry> =
                        pool_vec.into_iter().map(|e| (e.index, e)).collect();
                    let Some(entry) = pool.get(&index) else {
                        continue;
                    };

                    let attempt_decrypt = || -> Result<Value, MannaError> {
                        let key_pair = Crypto::get_swap_encryption_key(
                            wallet.swap_mnemonic.clone(),
                        )?
                        .ok_or(MannaError::new("Missing swap encryption key".to_string()))?;
                        let wrapped_key =
                            ecies::decrypt(key_pair.secret_key.as_ref(), ciphertext_key.as_ref())
                                .map_err(|e| {
                                MannaError::from("key decryption".to_string(), e.to_string())
                            })?;

                        let swap_data_str = String::from_utf8(Crypto::aes_decrypt(
                            Crypto::vec_to_array(wrapped_key)?,
                            ciphertext_swap.to_vec(),
                            Some(format!("swap_v1-{index}")),
                        )?)
                        .map_err(|e| {
                            MannaError::from("swap data utf8 decode".to_string(), e.to_string())
                        })?;

                        let swap_data: Value =
                            serde_json::from_str(&swap_data_str).map_err(|e| {
                                MannaError::from("swap data json decode".to_string(), e.to_string())
                            })?;

                        Ok(swap_data)
                    };

                    if let Ok(swap_data) = attempt_decrypt() {
                        let reverse_pairs = get_minimal_runtime()
                            .block_on(api_config.get_boltz_client(network).get_reverse_pairs())
                            .map_err(|e| {
                                MannaError::from("boltz reverse fee".to_string(), e.to_string())
                            })?;

                        let pair = reverse_pairs
                            .get_btc_to_lbtc_pair()
                            .ok_or_else(|| MannaError::new("missing BTC-LBTC pair".into()))?;

                        let miner_fee_claim = pair.fees.miner_fees.claim;

                        let send_amount = swap_data["sendAmount"]
                            .as_u64()
                            .ok_or_else(|| MannaError::new("missing sendAmount".into()))?;

                        let created_at_str = row["created_at"]
                            .as_str()
                            .ok_or_else(|| MannaError::new("missing created_at".into()))?;

                        let creation_time = DateTime::parse_from_rfc3339(created_at_str)
                            .map_err(|e| MannaError::new(format!("invalid date: {e}")))?
                            .timestamp_millis() as u128;

                        let swap_tree = serde_json::from_value(swap_data["swapTree"].clone())
                            .map_err(|e| {
                                MannaError::from("swap tree json decode".to_string(), e.to_string())
                            })?;

                        let boltz_fee =
                            (send_amount as f64 * pair.fees.percentage / 100.0).ceil() as u64;

                        let signed_index = i64::try_from(*index).map_err(|_| {
                            MannaError::from(
                                "Casting".to_string(),
                                "overflow while casting u64 to i64".to_string(),
                            )
                        })?;
                        let swap = Swap {
                            id: swap_data["id"].as_str().unwrap_or("").to_string(),
                            index: signed_index,
                            wallet_id: wallet.uuid.to_string(),
                            wallet_type: wallet.wallet_type.clone(),
                            network: *network,
                            preimage: entry.preimage.clone(),
                            send_amount,
                            receive_amount: swap_data["onchainAmount"]
                                .as_u64()
                                .unwrap_or(0)
                                .saturating_sub(miner_fee_claim),
                            creation_time,
                            completion_time: if let Some(data) = server_data
                                && let Some(completed_at_str) = data["completed_at"].as_str()
                            {
                                Some(
                                    DateTime::parse_from_rfc3339(completed_at_str)
                                        .map_err(|e| MannaError::new(format!("invalid date: {e}")))?
                                        .timestamp_millis()
                                        as u128,
                                )
                            } else {
                                None
                            },
                            submarine: None,
                            reverse: Some(ReverseSwap {
                                to: Chain::Liquid,
                                keys: entry.claim_key.clone(),
                                swap_create_res: ReverseResponse {
                                    invoice: swap_data["invoice"].as_str().map(str::to_string),
                                    swap_tree,
                                    lockup_address: swap_data["lockupAddress"]
                                        .as_str()
                                        .unwrap_or("")
                                        .to_string(),
                                    refund_public_key: swap_data["refundPublicKey"]
                                        .as_str()
                                        .unwrap_or("")
                                        .to_string(),
                                    timeout_block_height: swap_data["timeoutBlockHeight"]
                                        .as_u64()
                                        .unwrap_or(0)
                                        as u32,
                                    onchain_amount: swap_data["onchainAmount"]
                                        .as_u64()
                                        .unwrap_or(0),
                                    blinding_key: swap_data["blindingKey"]
                                        .as_str()
                                        .map(str::to_string),
                                },
                            }),
                            chain: None,
                            swap_status: if let Some(data) = server_data
                                && let Some(status) = data["status"].as_str()
                            {
                                status.to_string()
                            } else {
                                row["status"].as_str().unwrap_or("swap.created").to_string()
                            },
                            failure_reason: None,
                            note: swap_data["note"].as_str().map(str::to_string),
                            boltz_fee: Some(boltz_fee),
                            lockup_fee: Some(pair.fees.miner_fees.lockup),
                            claim_fee: Some(miner_fee_claim),
                            refunded_address: None,
                            refund_fee: None,
                            transactions: if let Some(data) = server_data
                                && let Some(tx_id) = data["claim_tx_id"].as_str()
                            {
                                vec![SwapTransaction {
                                    tx_id: tx_id.to_string(),
                                    chain: Chain::Liquid,
                                    tx_type: SwapTransactionType::Claim,
                                    is_user: true,
                                }]
                            } else {
                                vec![]
                            },
                            is_exchange_swap: false,
                            expected_lockup_amount: None,
                        };

                        fetched_swaps.push(swap);
                        break;
                    }
                }
            }
        }

        if !fetched_swaps.is_empty() {
            let ids = fetched_swaps
                .iter()
                .map(|w| w.id.clone())
                .collect::<Vec<_>>()
                .join(",");

            ureq::delete(format!(
                "https://{}.supabase.co/rest/v1/pending_lnurl_swaps?id=in.({ids})",
                supabase_config.project_ref
            ))
            .header("apikey", &*supabase_config.api_key)
            .header("Authorization", &format!("Bearer {jwt_token}"))
            .call()
            .map_err(|e| {
                MannaError::from("deletePendingSwapSupabase".to_string(), e.to_string())
            })?;
        }

        Ok(fetched_swaps)
    }
}
