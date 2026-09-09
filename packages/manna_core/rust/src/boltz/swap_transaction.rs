use crate::boltz::error::BoltzError;
use crate::boltz::types::{ApiConfig, Chain, ChainSwapDirection, Swap};
use boltz_client::reqwest::Client as HttpClient;
use boltz_client::{bitcoin, ToHex};
use lwk_wollet::bitcoin::Address as BitcoinAddress;
use lwk_wollet::elements::Address as LwkAddress;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::LazyLock;
use std::time::Duration;
use tracing::instrument;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub enum SwapTransactionType {
    Lockup,
    Claim,
    Refund,
}

impl SwapTransactionType {
    fn as_str(&self) -> &'static str {
        match self {
            SwapTransactionType::Lockup => "Lockup",
            SwapTransactionType::Claim => "Claim",
            SwapTransactionType::Refund => "Refund",
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SwapTransaction {
    pub tx_id: String,
    pub chain: Chain,
    pub tx_type: SwapTransactionType,
    // true if tx is done by app, false if it's done by boltz
    pub is_user: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct EsploraTransaction {
    txid: String,
    vin: Vec<EsploraVin>,
    vout: Vec<EsploraVout>,
}

#[derive(Clone, Serialize, Deserialize)]
struct EsploraVin {
    txid: String,
    vout: u32,
    prevout: Option<EsploraVout>,
    witness: Option<Vec<String>>,
}

#[derive(Clone, Serialize, Deserialize)]
struct EsploraVout {
    scriptpubkey: String,
    scriptpubkey_type: String,
    scriptpubkey_address: Option<String>,
}

fn get_public_address(address: &str) -> String {
    match LwkAddress::from_str(address)
        .map_err(|e| BoltzError::new("Parsing".to_string(), e.to_string()))
    {
        Ok(liquid_address) => liquid_address.to_unconfidential().to_string(),
        Err(_) => address.to_string(),
    }
}

fn get_script_pub_key_hex(address: &str) -> Result<String, BoltzError> {
    let lwk_script = LwkAddress::from_str(address).map(|addr| addr.script_pubkey().to_bytes());
    let btc_script = BitcoinAddress::from_str(address)
        .map(|addr| addr.assume_checked().script_pubkey().to_bytes());

    let bytes = lwk_script.or(btc_script).map_err(|_| {
        BoltzError::new(
            "Parsing".to_string(),
            "Address is neither a valid Bitcoin nor Liquid address".to_string(),
        )
    })?;

    Ok(bitcoin::ScriptBuf::from(bytes).to_hex())
}

pub(crate) fn push_swap_transaction(swap: &mut Swap, swap_transaction: SwapTransaction) {
    if !swap
        .transactions
        .iter()
        .any(|tx| tx.tx_id == swap_transaction.tx_id)
    {
        tracing::info!(
            "Pushing swap tx {}: {}...{} ({}, {}, {})",
            swap.id,
            swap_transaction.tx_id[..5].to_string(),
            swap_transaction.tx_id[swap_transaction.tx_id.len() - 5..].to_string(),
            (if swap_transaction.is_user {
                "User"
            } else {
                "Boltz"
            })
            .to_string(),
            swap_transaction.tx_type.as_str(),
            swap_transaction.chain.as_str()
        );

        swap.transactions.push(swap_transaction);
    }
}

fn find_lockup_output_index(tx: &EsploraTransaction, lockup_script: &str) -> Option<u32> {
    tx.vout
        .iter()
        .position(|vout| {
            vout.scriptpubkey_type.to_lowercase() == "v1_p2tr" && vout.scriptpubkey == lockup_script
        })
        .map(|i| i as u32)
}

fn spends_output(tx: &EsploraTransaction, txid: &str, vout: u32) -> bool {
    tx.vin
        .iter()
        .any(|vin| vin.txid == txid && vin.vout == vout)
}

/// returns (is_key_path, is_refund)
fn is_non_cooperative_refund(
    tx: &EsploraTransaction,
    lockup_txid: String,
    lockup_vout: u32,
    refund_script: &str,
) -> bool {
    let witness = tx
        .vin
        .iter()
        .find(|vin| vin.txid == lockup_txid && vin.vout == lockup_vout)
        .and_then(|vin| vin.witness.as_ref());

    // Key path spend: witness length will be 1
    if let Some(witness) = witness {
        witness.len() > 1 && witness.iter().any(|item| item == refund_script)
    } else {
        false
    }
}

static EXPECTED_TX_COUNT_SUBMARINE: LazyLock<HashMap<&'static str, u8>> = LazyLock::new(|| {
    HashMap::from([
        ("swap.created", 0),
        ("transaction.lockupFailed", 1),
        ("transaction.mempool", 1),
        ("transaction.confirmed", 1),
        ("invoice.set", 0),
        ("invoice.pending", 1),
        ("invoice.failedToPay", 1),
        ("invoice.paid", 1),
        ("transaction.claim.pending", 1),
        ("transaction.claimed", 2),
        ("swap.refunded", 2),
    ])
});
static EXPECTED_TX_COUNT_REVERSE: LazyLock<HashMap<&'static str, u8>> = LazyLock::new(|| {
    HashMap::from([
        ("swap.created", 0),
        ("minerfee.paid", 0),
        ("transaction.mempool", 1),
        ("transaction.confirmed", 1),
        ("invoice.settled", 2),
        ("invoice.expired", 0),
        ("transaction.failed", 0),
        ("transaction.refunded", 2),
    ])
});
static EXPECTED_TX_COUNT_CHAIN: LazyLock<HashMap<&'static str, u8>> = LazyLock::new(|| {
    HashMap::from([
        ("swap.created", 0),
        ("transaction.zeroconf.rejected", 0),
        ("transaction.lockupFailed", 1),
        ("transaction.mempool", 1),
        ("transaction.confirmed", 1),
        ("transaction.server.mempool", 2),
        ("transaction.server.confirmed", 2),
        ("transaction.claimed", 4),
        ("transaction.failed", 1),
        ("transaction.refunded", 3),
        ("swap.refunded", 2),
    ])
});

/// fetches swap transactions from esplora and return swap with linked swap transactions.
#[instrument(err, skip_all, fields(swap.id, swap.swap_status, txLen= swap.transactions.len()))]
pub async fn fetch_and_link_swap_transactions(
    mut swap: Swap,
    api_config: &ApiConfig,
) -> Result<Swap, BoltzError> {
    // to link only confirmed txs: "{}/address/{}/txs/chain"
    // to link all txs: "{}/address/{}/txs"
    if swap.submarine.is_some() && swap.preimage.value.is_empty() && swap.completion_time.is_some()
    {
        let boltz_client = api_config.get_boltz_client(&swap.network);
        if let Ok(res) = boltz_client.get_submarine_preimage(&swap.id).await {
            let preimage = res.preimage;
            if !preimage.is_empty() {
                swap.preimage.value = preimage;
            }
        }
    }

    if matches!(swap.swap_status.as_str(), "swap.created" | "swap.refunded") {
        return Ok(swap);
    }

    let expected_tx_length_map = if swap.submarine.is_some() {
        &EXPECTED_TX_COUNT_SUBMARINE
    } else if swap.reverse.is_some() {
        &EXPECTED_TX_COUNT_REVERSE
    } else if swap.chain.is_some() {
        &EXPECTED_TX_COUNT_CHAIN
    } else {
        return Err(BoltzError::new(
            "Swap".to_string(),
            "Invalid swap: no swap data".to_string(),
        ));
    };
    let expected_tx_length = *expected_tx_length_map
        .get(swap.swap_status.as_str())
        .unwrap_or(&0);

    if (swap.transactions.len() as u8) >= expected_tx_length {
        return Ok(swap);
    }

    let delays = [
        Duration::from_millis(0),
        Duration::from_millis(5000),
        Duration::from_millis(10000),
    ];
    for delay in delays {
        if (swap.transactions.len() as u8) >= expected_tx_length {
            return Ok(swap);
        }
        tokio::time::sleep(delay).await;
        tracing::info!(
            "Fetching txs {}({}) after {} ms. {}/{}",
            swap.id,
            swap.swap_status,
            delay.as_millis(),
            swap.transactions.len(),
            expected_tx_length
        );
        fetch_and_link_swap_transaction_inner_call(api_config, &mut swap).await?;
    }

    Ok(swap)
}

async fn fetch_and_link_swap_transaction_inner_call(
    api_config: &ApiConfig,
    swap: &mut Swap,
) -> Result<(), BoltzError> {
    let client = HttpClient::new();
    let bitcoin_esplora_url = api_config.get_esplora_url(&swap.network, &Chain::Bitcoin);
    let liquid_esplora_url = api_config.get_esplora_url(&swap.network, &Chain::Liquid);

    if swap.submarine.is_some() || swap.reverse.is_some() {
        let is_submarine = swap.submarine.is_some();

        let lockup_address = swap
            .submarine
            .as_ref()
            .map(|s| s.swap_create_res.address.clone())
            .or_else(|| {
                swap.reverse
                    .as_ref()
                    .map(|s| s.swap_create_res.lockup_address.clone())
            });
        if let Some(address) = lockup_address {
            let lockup_script_pubkey = get_script_pub_key_hex(&address)?;
            let url = format!(
                "{}/address/{}/txs",
                liquid_esplora_url,
                get_public_address(&address)
            );
            let response = client
                .get(&url)
                .send()
                .await
                .map_err(|e| BoltzError::esplora_error(e.to_string()))?;

            if !response.status().is_success() {
                return Ok(());
            }

            let transactions: Vec<EsploraTransaction> = response
                .json()
                .await
                .map_err(|e| BoltzError::esplora_error(e.to_string()))?;

            let lockup_tx = transactions.iter().find(|tx| {
                tx.vout.iter().any(|vout| {
                    vout.scriptpubkey_type.to_lowercase() == "v1_p2tr"
                        && vout.scriptpubkey == lockup_script_pubkey
                })
            });

            if let Some(tx) = lockup_tx {
                let lockup_txid = tx.txid.clone();
                let lockup_vout =
                    find_lockup_output_index(tx, &lockup_script_pubkey).ok_or_else(|| {
                        BoltzError::new(
                            "Parsing".to_string(),
                            "Lockup output not found".to_string(),
                        )
                    })?;

                push_swap_transaction(
                    swap,
                    SwapTransaction {
                        tx_id: lockup_txid.clone(),
                        chain: Chain::Liquid,
                        tx_type: SwapTransactionType::Lockup,
                        is_user: is_submarine, // if swap is submarine, manna locked up, for reverse swap boltz locked up
                    },
                );

                let spending_tx = transactions
                    .iter()
                    .find(|tx| spends_output(tx, &lockup_txid, lockup_vout));

                if let Some(spending_tx) = spending_tx {
                    let mut is_refund = false;
                    let refund_script = swap
                        .submarine
                        .as_ref()
                        .map(|s| s.swap_create_res.swap_tree.refund_leaf.output.clone())
                        .or(swap
                            .reverse
                            .as_ref()
                            .map(|r| r.swap_create_res.swap_tree.refund_leaf.output.clone()));

                    if let Some(refund_script) = refund_script
                        && is_non_cooperative_refund(
                            spending_tx,
                            lockup_txid,
                            lockup_vout,
                            refund_script.as_ref(),
                        )
                    {
                        is_refund = true;
                    }

                    // Fallback: check refund address in outputs
                    let refund_key = swap
                        .refunded_address
                        .as_ref()
                        .map(|a| get_script_pub_key_hex(a));

                    if !is_refund
                        && let Some(Ok(key)) = refund_key
                        && spending_tx.vout.iter().any(|v| v.scriptpubkey == key)
                    {
                        is_refund = true;
                    }

                    if is_refund {
                        push_swap_transaction(
                            swap,
                            SwapTransaction {
                                tx_id: spending_tx.txid.clone(),
                                chain: Chain::Liquid,
                                tx_type: SwapTransactionType::Refund,
                                is_user: is_submarine,
                            },
                        );
                        return Ok(());
                    }

                    push_swap_transaction(
                        swap,
                        SwapTransaction {
                            tx_id: spending_tx.txid.clone(),
                            chain: Chain::Liquid,
                            tx_type: SwapTransactionType::Claim,
                            is_user: !is_submarine,
                        },
                    );

                    return Ok(());
                }
            }
        }
    } else if let Some(chain) = swap.chain.clone() {
        let user_lockup_address = chain.lockup_details.lockup_address;
        let boltz_lockup_address = chain.claim_details.lockup_address;

        let source = match chain.direction {
            ChainSwapDirection::BtcToLbtc => Chain::Bitcoin,
            ChainSwapDirection::LbtcToBtc => Chain::Liquid,
        };
        let dest = match chain.direction {
            ChainSwapDirection::BtcToLbtc => Chain::Liquid,
            ChainSwapDirection::LbtcToBtc => Chain::Bitcoin,
        };

        // process source chain transactions
        {
            let lockup_script_pubkey = get_script_pub_key_hex(&user_lockup_address)?;
            let url = format!(
                "{}/address/{}/txs",
                match source {
                    Chain::Bitcoin => bitcoin_esplora_url.clone(),
                    Chain::Liquid => liquid_esplora_url.clone(),
                },
                get_public_address(&user_lockup_address)
            );
            let response = client
                .get(&url)
                .send()
                .await
                .map_err(|e| BoltzError::esplora_error(e.to_string()))?;

            if !response.status().is_success() {
                return Ok(());
            }

            let transactions: Vec<EsploraTransaction> = response
                .json()
                .await
                .map_err(|e| BoltzError::esplora_error(e.to_string()))?;

            let lockup_tx = transactions.iter().find(|tx| {
                tx.vout.iter().any(|vout| {
                    vout.scriptpubkey_type.to_lowercase() == "v1_p2tr"
                        && vout.scriptpubkey == lockup_script_pubkey
                })
            });

            if let Some(tx) = lockup_tx {
                let lockup_txid = tx.txid.clone();
                let lockup_vout =
                    find_lockup_output_index(tx, &lockup_script_pubkey).ok_or_else(|| {
                        BoltzError::new(
                            "Parsing".to_string(),
                            "Lockup output not found".to_string(),
                        )
                    })?;

                push_swap_transaction(
                    swap,
                    SwapTransaction {
                        tx_id: lockup_txid.clone(),
                        chain: source,
                        tx_type: SwapTransactionType::Lockup,
                        is_user: true,
                    },
                );

                let spending_tx = transactions
                    .iter()
                    .find(|tx| spends_output(tx, &lockup_txid, lockup_vout));

                if let Some(spending_tx) = spending_tx {
                    let mut is_refund = is_non_cooperative_refund(
                        spending_tx,
                        lockup_txid,
                        lockup_vout,
                        chain.lockup_details.swap_tree.refund_leaf.output.as_ref(),
                    );

                    // Fallback: check refund address in outputs
                    let refund_key = swap
                        .refunded_address
                        .as_ref()
                        .or(chain.lockup_details.refund_address.as_ref())
                        .map(|a| get_script_pub_key_hex(a));

                    if !is_refund
                        && let Some(Ok(key)) = refund_key
                        && spending_tx.vout.iter().any(|v| v.scriptpubkey == key)
                    {
                        is_refund = true;
                    }

                    push_swap_transaction(
                        swap,
                        SwapTransaction {
                            tx_id: spending_tx.txid.clone(),
                            chain: source,
                            tx_type: match is_refund {
                                true => SwapTransactionType::Refund,
                                false => SwapTransactionType::Claim,
                            },
                            is_user: is_refund, // on source chain swap start with user lockup so refund means user refund and claim means boltz claim
                        },
                    );
                }
            }
        }

        // process destination chain transactions
        {
            let lockup_script_pubkey = get_script_pub_key_hex(&boltz_lockup_address)?;
            let url = format!(
                "{}/address/{}/txs",
                match source {
                    Chain::Bitcoin => liquid_esplora_url,
                    Chain::Liquid => bitcoin_esplora_url,
                },
                get_public_address(&boltz_lockup_address)
            );
            let response = client
                .get(&url)
                .send()
                .await
                .map_err(|e| BoltzError::esplora_error(e.to_string()))?;

            if !response.status().is_success() {
                return Ok(());
            }

            let transactions: Vec<EsploraTransaction> = response
                .json()
                .await
                .map_err(|e| BoltzError::esplora_error(e.to_string()))?;

            let lockup_tx = transactions.iter().find(|tx| {
                tx.vout.iter().any(|vout| {
                    vout.scriptpubkey_type.to_lowercase() == "v1_p2tr"
                        && vout.scriptpubkey == lockup_script_pubkey
                })
            });

            if let Some(tx) = lockup_tx {
                let lockup_txid = tx.txid.clone();
                let lockup_vout =
                    find_lockup_output_index(tx, &lockup_script_pubkey).ok_or_else(|| {
                        BoltzError::new(
                            "Parsing".to_string(),
                            "Lockup output not found".to_string(),
                        )
                    })?;
                push_swap_transaction(
                    swap,
                    SwapTransaction {
                        tx_id: lockup_txid.clone(),
                        chain: dest,
                        tx_type: SwapTransactionType::Lockup,
                        is_user: false,
                    },
                );

                let spending_tx = transactions
                    .iter()
                    .find(|tx| spends_output(tx, &lockup_txid, lockup_vout));

                if let Some(spending_tx) = spending_tx {
                    let mut is_refund = is_non_cooperative_refund(
                        spending_tx,
                        lockup_txid,
                        lockup_vout,
                        chain.claim_details.swap_tree.refund_leaf.output.as_ref(),
                    );

                    // Fallback: check refund address in outputs
                    let refund_key = swap
                        .refunded_address
                        .as_ref()
                        .or(chain.claim_details.refund_address.as_ref())
                        .map(|a| get_script_pub_key_hex(a));

                    if !is_refund
                        && let Some(Ok(key)) = refund_key
                        && spending_tx.vout.iter().any(|v| v.scriptpubkey == key)
                    {
                        is_refund = true;
                    }

                    push_swap_transaction(
                        swap,
                        SwapTransaction {
                            tx_id: spending_tx.txid.clone(),
                            chain: dest,
                            tx_type: match is_refund {
                                true => SwapTransactionType::Refund,
                                false => SwapTransactionType::Claim,
                            },
                            is_user: !is_refund, // on destination chain, refund means boltz refunded their coins and claim means user claimed theirs
                        },
                    );
                }
            }
        }
    }

    Ok(())
}
