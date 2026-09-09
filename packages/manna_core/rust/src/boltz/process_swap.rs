use crate::boltz::error::BoltzError;
use crate::boltz::swap_transaction::{
    fetch_and_link_swap_transactions, push_swap_transaction, SwapTransaction, SwapTransactionType,
};
use crate::boltz::types::{ApiConfig, Chain, ChainSwapDirection, PreImage, Swap, TxFee};
use crate::boltz::BoltzManager;
use crate::lwk::types::Address;
use crate::util::{get_current_time, LiquidWallet, Network};
use boltz_client::boltz::{
    GetChainPairsResponse, GetReversePairsResponse, GetSubmarinePairsResponse, SwapTxKind,
};
use dashmap::DashMap;
use flutter_rust_bridge::{frb, DartFnFuture};
use once_cell::sync::Lazy;
use serde_json::json;
use tracing::instrument;

#[frb(ignore)]
struct PairCache {
    submarine: DashMap<Network, (u128, GetSubmarinePairsResponse)>,
    reverse: DashMap<Network, (u128, GetReversePairsResponse)>,
    chain: DashMap<Network, (u128, GetChainPairsResponse)>,
}

#[frb(ignore)]
static FEE_CACHE: Lazy<PairCache> = Lazy::new(|| PairCache {
    submarine: DashMap::new(),
    reverse: DashMap::new(),
    chain: DashMap::new(),
});

impl PairCache {
    async fn get_submarine(
        &self,
        api_config: &ApiConfig,
        network: Network,
    ) -> Result<GetSubmarinePairsResponse, BoltzError> {
        if let Some(pair) = self.submarine.get(&network) {
            let pair = pair.clone();
            if get_current_time() - pair.0
                < api_config.get_config(&network).boltz_fee_cache_timeout_ms as u128
            {
                return Ok(pair.1);
            }
        }

        println!("fetching submarine fees");
        let fresh_data = api_config
            .get_boltz_client(&network)
            .get_submarine_pairs()
            .await?;
        self.submarine
            .insert(network, (get_current_time(), fresh_data.clone()));
        Ok(fresh_data)
    }

    async fn get_reverse(
        &self,
        api_config: &ApiConfig,
        network: Network,
    ) -> Result<GetReversePairsResponse, BoltzError> {
        if let Some(pair) = self.reverse.get(&network) {
            let pair = pair.clone();
            if get_current_time() - pair.0
                < api_config.get_config(&network).boltz_fee_cache_timeout_ms as u128
            {
                return Ok(pair.1);
            }
        }

        println!("fetching reverse fees");
        let fresh_data = api_config
            .get_boltz_client(&network)
            .get_reverse_pairs()
            .await?;
        self.reverse
            .insert(network, (get_current_time(), fresh_data.clone()));
        Ok(fresh_data)
    }

    async fn get_chain(
        &self,
        api_config: &ApiConfig,
        network: Network,
    ) -> Result<GetChainPairsResponse, BoltzError> {
        if let Some(pair) = self.chain.get(&network) {
            let pair = pair.clone();
            if get_current_time() - pair.0
                < api_config.get_config(&network).boltz_fee_cache_timeout_ms as u128
            {
                return Ok(pair.1);
            }
        }

        println!("fetching chain fees");
        let fresh_data = api_config
            .get_boltz_client(&network)
            .get_chain_pairs()
            .await?;
        self.chain
            .insert(network, (get_current_time(), fresh_data.clone()));
        Ok(fresh_data)
    }
}

pub async fn get_submarine_json(
    api_config: &ApiConfig,
    network: Network,
) -> Result<String, BoltzError> {
    serde_json::to_string(&FEE_CACHE.get_submarine(api_config, network).await?)
        .map_err(|e| BoltzError::new("JSON".to_string(), e.to_string()))
}

pub async fn get_reverse_json(
    api_config: &ApiConfig,
    network: Network,
) -> Result<String, BoltzError> {
    serde_json::to_string(&FEE_CACHE.get_reverse(api_config, network).await?)
        .map_err(|e| BoltzError::new("JSON".to_string(), e.to_string()))
}

pub async fn get_chain_json(
    api_config: &ApiConfig,
    network: Network,
) -> Result<String, BoltzError> {
    serde_json::to_string(&FEE_CACHE.get_chain(api_config, network).await?)
        .map_err(|e| BoltzError::new("JSON".to_string(), e.to_string()))
}

fn get_liquid_address(
    liquid_wallets: &[LiquidWallet],
    swap: &Swap,
    lwk_path: &String,
) -> Result<Address, BoltzError> {
    let wallet = liquid_wallets
        .iter()
        .find(|wallet| wallet.uuid == swap.wallet_id && wallet.wallet_type == swap.wallet_type)
        .ok_or(BoltzError::new(
            "Invalid Data".to_string(),
            "Missing matching liquid wallet".to_string(),
        ))?;
    Ok(wallet
        .init(lwk_path.clone(), swap.network)?
        .address_last_unused()
        .map_err(|e| BoltzError::new("LWK".to_string(), e.msg))?)
}

/// call this function to process the swap based on the status, the passed swap should have updated status
///
/// returns None if swap is not handled else returns updated swap and<br>
///     [Some(true)] if chain swap can be negotiated but automatic negotiation failed and user intervention required.<br>
///     [Some(false)] if refund requires user intervention and automatic refund failed.<br>
///     [None]: swap is processed successfully.
///
/// [device_id] is passed to backend to exclude notification for following device
#[instrument(err, skip_all, fields(swap.id))]
pub async fn process_swap(
    mut swap: Swap,
    boltz_manager: &BoltzManager,
    lwk_path: String,
    liquid_wallets: Vec<LiquidWallet>,
    on_receiving_claim_start: impl Fn(Swap) -> DartFnFuture<()>,
    on_receiving_claim_complete: impl Fn(Swap) -> DartFnFuture<()>,
    device_id: Option<String>,
) -> Result<Option<(Swap, Option<bool>)>, BoltzError> {
    if swap.completion_time.is_some() {
        return Ok(None);
    }

    if matches!(swap.swap_status.as_str(), "swap.created" | "swap.refunded") {
        return Ok(None);
    }

    swap = fetch_and_link_swap_transactions(swap, &boltz_manager.api_config).await?;

    let r = is_final_swap_state(&swap);
    if r.1 {
        return Ok(Some((r.0, None)));
    }

    tracing::info!("processing swap: {}-{}", swap.id, swap.swap_status);

    // process submarine swap
    if let Some(submarine) = &swap.submarine {
        // Coop claim
        if swap.swap_status == "transaction.claim.pending" {
            // lbtc minimal limit check, swap amount larger than that can be closed by boltz immediately.
            // lower amount (minimalBatched) swaps are claimed by boltz in batches.
            let fee = FEE_CACHE
                .get_submarine(&boltz_manager.api_config, swap.network)
                .await?;
            let boltz_client = boltz_manager.api_config.get_boltz_client(&swap.network);
            if let Some(pair) = fee.get_lbtc_to_btc_pair()
                && swap.receive_amount >= pair.limits.minimal
            {
                boltz_manager.close_submarine_coop(&swap).await?;
            }

            let preimage_res = boltz_client
                .get_submarine_preimage(swap.id.as_str())
                .await?;
            swap.preimage = PreImage::from_string(preimage_res.preimage.as_str())?;

            swap.completion_time = Some(get_current_time());
            return Ok(Some((swap, None)));
        }

        // refund
        let is_manna_locked_up = swap
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Lockup && t.is_user);
        if is_manna_locked_up
            && (matches!(
                swap.swap_status.as_str(),
                "invoice.failedToPay" | "transaction.lockupFailed" | "swap.expired"
            ) || swap.failure_reason.is_some())
        {
            if submarine.from == Chain::Bitcoin {
                return Err(BoltzError::new(
                    "Invalid Data".to_string(),
                    "Can't refund bitcoin submarine swap, missing refund address".to_string(),
                ));
            }

            let refund_address = get_liquid_address(&liquid_wallets, &swap, &lwk_path)
                .map_err(|e| {
                    BoltzError::new(
                        e.kind,
                        format!("Can't refund liquid submarine swap, {}", e.message),
                    )
                })?
                .confidential;

            let fee = FEE_CACHE
                .get_submarine(&boltz_manager.api_config, swap.network)
                .await?;

            if let Some(pair) = fee.get_lbtc_to_btc_pair() {
                let miner_fee = TxFee {
                    absolute: Some(pair.fees.miner_fees),
                    relative: None,
                };
                let tx_hex = match boltz_manager
                    .refund_submarine(&swap, &refund_address, miner_fee, true)
                    .await
                {
                    Ok(tx_hex) => Ok(tx_hex),
                    // If it fails, try again with try_cooperate = false
                    Err(_) => {
                        boltz_manager
                            .refund_submarine(&swap, &refund_address, miner_fee, false)
                            .await
                    }
                }?;
                let tx_id = boltz_manager
                    .broadcast_swap_tx(tx_hex, swap.network, Chain::Liquid)
                    .await?;

                if !tx_id.is_empty() {
                    swap.refunded_address = Some(refund_address);
                    swap.refund_fee = Some(pair.fees.miner_fees);
                    swap.swap_status = "swap.refunded".to_string();
                    push_swap_transaction(
                        &mut swap,
                        SwapTransaction {
                            tx_id,
                            chain: Chain::Liquid,
                            tx_type: SwapTransactionType::Refund,
                            is_user: true,
                        },
                    );

                    return Ok(Some((swap, None)));
                }
            }
        }
    } else if let Some(reverse) = &swap.reverse {
        let is_manna_claimed = swap
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Claim && t.is_user);

        if matches!(
            swap.swap_status.as_str(),
            "transaction.mempool" | "transaction.confirmed"
        ) && !is_manna_claimed
        {
            if reverse.to == Chain::Bitcoin {
                return Err(BoltzError::new(
                    "Invalid Data".to_string(),
                    "Can't claim bitcoin reverse submarine swap, missing claim address".to_string(),
                ));
            }

            let address = get_liquid_address(&liquid_wallets, &swap, &lwk_path).map_err(|e| {
                BoltzError::new(e.kind, format!("Can't claim reverse swap, {}", e.message))
            })?;
            let claim_address = address.confidential;

            on_receiving_claim_start(swap.clone()).await;

            let fee = FEE_CACHE
                .get_reverse(&boltz_manager.api_config, swap.network)
                .await?;
            if let Some(pair) = fee.get_btc_to_lbtc_pair() {
                let miner_fee = TxFee {
                    absolute: Some(pair.fees.miner_fees.claim),
                    relative: None,
                };
                let tx_hex = match boltz_manager
                    .claim_reverse(&swap, &claim_address, miner_fee, true)
                    .await
                {
                    Ok(tx_hex) => Ok(tx_hex),
                    // If it fails, try again with try_cooperate = false
                    Err(_) => {
                        boltz_manager
                            .claim_reverse(&swap, &claim_address, miner_fee, false)
                            .await
                    }
                }?;
                let tx_id = boltz_manager
                    .broadcast_swap_tx(tx_hex, swap.network, Chain::Liquid)
                    .await?;

                if !tx_id.is_empty() {
                    push_swap_transaction(
                        &mut swap,
                        SwapTransaction {
                            tx_id: tx_id.clone(),
                            chain: Chain::Liquid,
                            tx_type: SwapTransactionType::Claim,
                            is_user: true,
                        },
                    );

                    let _ = send_notification_to_other_devices(
                        tx_id,
                        &swap,
                        &claim_address,
                        address.index.ok_or(BoltzError::new(
                            "LWK".to_string(),
                            "Missing address index".to_string(),
                        ))?,
                        &boltz_manager.api_config,
                        device_id,
                    );
                    swap.completion_time = Some(get_current_time());

                    on_receiving_claim_complete(swap.clone()).await;
                    return Ok(Some((swap, None)));
                }
            }
        }
    } else if let Some(chain) = swap.chain.clone() {
        let is_manna_locked_up = swap
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Lockup && t.is_user);
        let is_manna_claimed = swap
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Claim && t.is_user);
        let is_manna_refunded = swap
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Refund && t.is_user);

        // claim
        if matches!(
            swap.swap_status.as_str(),
            "transaction.server.mempool" | "transaction.server.confirmed"
        ) && !is_manna_claimed
        {
            let (claim_address, liquid_claim_address_index) = match chain.direction {
                ChainSwapDirection::BtcToLbtc => {
                    let address =
                        get_liquid_address(&liquid_wallets, &swap, &lwk_path).map_err(|e| {
                            BoltzError::new(
                                e.kind,
                                format!("Can't claim chain swap, {}", e.message),
                            )
                        })?;
                    (address.confidential, address.index)
                }
                ChainSwapDirection::LbtcToBtc => (
                    chain
                        .claim_details
                        .claim_address
                        .clone()
                        .ok_or(BoltzError::new(
                            "Invalid Data".to_string(),
                            "Can't claim chain swap, missing claim address".to_string(),
                        ))?,
                    None,
                ),
            };

            on_receiving_claim_start(swap.clone()).await;

            let fee = FEE_CACHE
                .get_chain(&boltz_manager.api_config, swap.network)
                .await?;
            if let Some(pair) = match chain.direction {
                ChainSwapDirection::BtcToLbtc => fee.get_btc_to_lbtc_pair(),
                ChainSwapDirection::LbtcToBtc => fee.get_lbtc_to_btc_pair(),
            } {
                let miner_fee = TxFee {
                    absolute: Some(pair.fees.miner_fees.user.claim),
                    relative: None,
                };
                let tx_hex = match boltz_manager
                    .claim_chain(
                        &swap,
                        &claim_address,
                        &chain.lockup_details.lockup_address,
                        miner_fee,
                        true,
                    )
                    .await
                {
                    Ok(tx_hex) => Ok(tx_hex),
                    // If it fails, try again with try_cooperate = false
                    Err(_) => {
                        boltz_manager
                            .claim_chain(
                                &swap,
                                &claim_address,
                                &chain.lockup_details.lockup_address,
                                miner_fee,
                                false,
                            )
                            .await
                    }
                }?;
                let tx_id = boltz_manager
                    .broadcast_swap_tx(
                        tx_hex,
                        swap.network,
                        match chain.direction {
                            ChainSwapDirection::BtcToLbtc => Chain::Liquid,
                            ChainSwapDirection::LbtcToBtc => Chain::Bitcoin,
                        },
                    )
                    .await?;

                if !tx_id.is_empty() {
                    push_swap_transaction(
                        &mut swap,
                        SwapTransaction {
                            tx_id: tx_id.clone(),
                            chain: match chain.direction {
                                ChainSwapDirection::BtcToLbtc => Chain::Liquid,
                                ChainSwapDirection::LbtcToBtc => Chain::Bitcoin,
                            },
                            tx_type: SwapTransactionType::Claim,
                            is_user: true,
                        },
                    );
                    if let Some(address_index) = liquid_claim_address_index
                        && chain.direction == ChainSwapDirection::BtcToLbtc
                    {
                        let _ = send_notification_to_other_devices(
                            tx_id,
                            &swap,
                            &claim_address,
                            address_index,
                            &boltz_manager.api_config,
                            device_id,
                        );
                    }
                    swap.completion_time = Some(get_current_time());

                    on_receiving_claim_complete(swap.clone()).await;
                    return Ok(Some((swap, None)));
                }
            }
        }

        // negotiation or refund
        if is_manna_locked_up && !is_manna_refunded && !is_manna_claimed {
            if let Some(reason) = &swap.failure_reason {
                // negotiation
                if get_current_time() - swap.creation_time < 23 * 60 * 60 * 1000
                    && reason.contains("locked")
                    && reason.contains("expected")
                    && swap.swap_status == "transaction.lockupFailed"
                {
                    // negotiable
                    // try to settle it automatically.
                    let quote = boltz_manager.get_chain_swap_quote(&swap).await;
                    if quote > 0 {
                        // check lockup tx to make sure quote matches lockup
                        let (btc_script, lbtc_script) = chain.get_scripts(&swap)?;
                        let boltz_client = boltz_manager.api_config.get_boltz_client(&swap.network);
                        let locked_amount = match chain.direction {
                            ChainSwapDirection::BtcToLbtc => btc_script
                                .fetch_lockup_utxo_boltz(
                                    swap.network.bitcoin(),
                                    &boltz_client,
                                    swap.id.as_str(),
                                    SwapTxKind::Refund,
                                )
                                .await?
                                .map(|e| e.1.value.to_sat()),
                            ChainSwapDirection::LbtcToBtc => Some(
                                lbtc_script
                                    .fetch_lockup_utxo_boltz(
                                        swap.network.liquid(),
                                        &boltz_client,
                                        swap.id.as_str(),
                                        SwapTxKind::Refund,
                                    )
                                    .await?
                                    .1
                                    .minimum_value(),
                            ),
                        };

                        if let Some(locked) = locked_amount {
                            // if the swap is buy bitcoin swap and if the locked amount is less than expected amount,
                            // let user handle the negotiation
                            if swap.is_exchange_swap
                                && swap.expected_lockup_amount.is_some()
                                && locked < swap.expected_lockup_amount.unwrap()
                            {
                                return Ok(Some((swap, Some(true))));
                            }

                            let fee = FEE_CACHE
                                .get_chain(&boltz_manager.api_config, swap.network)
                                .await?;
                            let lockup_fee = swap.lockup_fee.unwrap_or(0);
                            let claim_fee = swap.claim_fee.unwrap_or(0);
                            let total_percent_fee =
                                swap.send_amount - swap.receive_amount - lockup_fee - claim_fee;
                            if total_percent_fee > 0
                                && let Some(boltz_percent_fee) = match chain.direction {
                                    ChainSwapDirection::BtcToLbtc => fee.get_btc_to_lbtc_pair(),
                                    ChainSwapDirection::LbtcToBtc => fee.get_lbtc_to_btc_pair(),
                                }
                                .map(|e| e.fees.percentage)
                            {
                                let manna_percent_fee = (total_percent_fee as f64 * 100.0
                                    / swap.send_amount as f64)
                                    - boltz_percent_fee;

                                let new_total_fee =
                                    (locked as f64 * (boltz_percent_fee + manna_percent_fee)
                                        / 100.0)
                                        .ceil() as u64
                                        + lockup_fee
                                        + claim_fee;

                                let new_send_amount = locked;
                                let new_receive_amount = quote - claim_fee;
                                let difference =
                                    new_receive_amount.abs_diff(locked - new_total_fee);

                                if difference <= 1 {
                                    let quote_accept_res =
                                        boltz_manager.accept_chain_swap_quote(&swap, quote).await?;
                                    if quote_accept_res {
                                        tracing::info!("Accepted quote : {}({})", quote, swap.id);
                                        swap.send_amount = new_send_amount;
                                        swap.receive_amount = new_receive_amount;
                                        swap.boltz_fee = Some(
                                            (locked as f64 * boltz_percent_fee / 100.0).ceil()
                                                as u64,
                                        );

                                        return Ok(Some((swap, None)));
                                    }
                                }
                            }
                        }
                        return Ok(Some((swap, Some(true))));
                    }
                }

                // Refund
                if matches!(
                    swap.swap_status.as_str(),
                    "swap.expired" | "transaction.lockupFailed" | "transaction.refunded"
                ) {
                    if chain.direction == ChainSwapDirection::LbtcToBtc {
                        // refund lbtc automatically
                        let refund_address = get_liquid_address(&liquid_wallets, &swap, &lwk_path)
                            .map_err(|e| {
                                BoltzError::new(
                                    e.kind,
                                    format!("Can't refund chain swap, {}", e.message),
                                )
                            })?
                            .confidential;

                        let fee = FEE_CACHE
                            .get_chain(&boltz_manager.api_config, swap.network)
                            .await?;
                        // Note: don't change pairs!
                        if let Some(pair) = match chain.direction {
                            ChainSwapDirection::BtcToLbtc => fee.get_lbtc_to_btc_pair(),
                            ChainSwapDirection::LbtcToBtc => fee.get_btc_to_lbtc_pair(),
                        } {
                            let miner_fee = TxFee {
                                absolute: Some(pair.fees.miner_fees.user.claim),
                                relative: None,
                            };
                            let tx_hex = match boltz_manager
                                .refund_chain(&swap, &refund_address, miner_fee, true)
                                .await
                            {
                                Ok(tx_hex) => Ok(tx_hex),
                                // If it fails, try again with try_cooperate = false
                                Err(_) => {
                                    boltz_manager
                                        .refund_chain(&swap, &refund_address, miner_fee, false)
                                        .await
                                }
                            }?;
                            let tx_id = boltz_manager
                                .broadcast_swap_tx(
                                    tx_hex,
                                    swap.network,
                                    match chain.direction {
                                        ChainSwapDirection::BtcToLbtc => Chain::Bitcoin,
                                        ChainSwapDirection::LbtcToBtc => Chain::Liquid,
                                    },
                                )
                                .await?;

                            if !tx_id.is_empty() {
                                swap.refunded_address = Some(refund_address);
                                swap.refund_fee = miner_fee.absolute;
                                swap.swap_status = "swap.refunded".to_string();
                                push_swap_transaction(
                                    &mut swap,
                                    SwapTransaction {
                                        tx_id,
                                        chain: match chain.direction {
                                            ChainSwapDirection::BtcToLbtc => Chain::Bitcoin,
                                            ChainSwapDirection::LbtcToBtc => Chain::Liquid,
                                        },
                                        tx_type: SwapTransactionType::Refund,
                                        is_user: true,
                                    },
                                );

                                return Ok(Some((swap, None)));
                            }
                        }
                    } else {
                        return Ok(Some((swap, Some(false))));
                    }
                }
            }
        }
    }

    Ok(None)
}

#[instrument(err, skip_all, fields(swap.id))]
fn send_notification_to_other_devices(
    tx_id: String,
    swap: &Swap,
    address: &str,
    address_index: u32,
    api_config: &ApiConfig,
    device_id: Option<String>,
) -> Result<(), BoltzError> {
    let mut body = json!({
          "txId": tx_id,
          "address": address,
          "addressIndex": address_index,
          "walletId": swap.wallet_id,
          "amount": swap.receive_amount,
    });
    if let Some(device_id) = device_id.filter(|s| !s.is_empty()) {
        body["deviceId"] = json!(device_id);
    }
    if let Some(note) = swap.note.as_ref().filter(|s| !s.is_empty()) {
        body["note"] = json!(note);
    }
    let ready_res = ureq::post(
        api_config
            .get_config(&swap.network)
            .get_server_api_endpoint("sendNotificationForClaimedSwaps"),
    )
    .send_json(body)
    .map_err(|e| {
        BoltzError::new(
            "Network".to_string(),
            format!("Can't send notification to other devices, {e}"),
        )
    })?;
    if ready_res.status() == 401 {
        return Err(BoltzError::new("Jwt".to_string(), "401".to_string()));
    }

    Ok(())
}

/// returns updated swap and true if swap is at its final state
#[frb(sync)]
pub fn is_final_swap_state(swap: &Swap) -> (Swap, bool) {
    let mut s: Swap = swap.clone();
    let status = s.swap_status.as_str();

    if status == "swap.refunded" {
        return (s, true);
    }

    if let Some(_) = s.submarine {
        let is_manna_locked_up = s
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Lockup && t.is_user);
        let is_manna_refunded = s
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Refund && t.is_user);

        // return on final status
        let is_success = status == "transaction.claimed";
        let is_expired_ok =
            s.swap_status == "swap.expired" && (!is_manna_locked_up || is_manna_refunded);
        let is_failed = matches!(status, "transaction.lockupFailed" | "invoice.failedToPay");

        if is_failed && is_manna_refunded {
            s.swap_status = "swap.refunded".to_string()
        }
        if is_success && s.completion_time.is_none() {
            s.completion_time = Some(get_current_time());
        }

        return (
            s,
            is_success
                || is_expired_ok
                || (is_failed && (!is_manna_locked_up || is_manna_refunded)),
        );
    } else if let Some(_) = s.reverse {
        let is_manna_claimed = s
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Claim && t.is_user);

        let is_success = status == "invoice.settled" || is_manna_claimed;
        let is_failure = matches!(
            status,
            "invoice.expired" | "transaction.failed" | "swap.expired" | "transaction.refunded"
        );

        if is_success {
            if s.completion_time.is_none() {
                s.completion_time = Some(get_current_time());
            }
            s.swap_status = "invoice.settled".to_string();
        }

        return (s, is_success || is_failure);
    } else if let Some(_) = s.chain {
        let is_manna_locked_up = s
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Lockup && t.is_user);
        let is_manna_refunded = s
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Refund && t.is_user);
        let is_manna_claimed = s
            .transactions
            .iter()
            .any(|t| t.tx_type == SwapTransactionType::Claim && t.is_user);

        let is_success = is_manna_claimed;
        let is_failed = matches!(
            status,
            "transaction.lockupFailed" | "transaction.failed" | "transaction.refunded"
        ) && !s.transactions.is_empty(); // the second condition is for edge case where the txs are never linked.
        let is_expired_ok =
            s.swap_status == "swap.expired" && (!is_manna_locked_up || is_manna_refunded);

        if is_failed && is_manna_refunded {
            s.swap_status = "swap.refunded".to_string();
        }
        if is_success && s.completion_time.is_none() {
            s.completion_time = Some(get_current_time());
        }

        return (
            s,
            is_success
                || is_expired_ok
                || (is_failed && (!is_manna_locked_up || is_manna_refunded)),
        );
    }

    (s, false)
}
