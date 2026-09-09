use crate::boltz::bolt12::parse_bolt12_invoice;
use crate::boltz::error::BoltzError;
use crate::boltz::types::{
    decode_bolt12_invoice, ApiConfig, Chain, ChainSwap, ChainSwapDirection, ExtraSwapFee, PreImage,
    ReverseResponse, ReverseSwap, SubmarineResponse, SubmarineSwap, Swap, TxFee, WebHook,
};
use crate::boltz::BoltzManager;
use crate::util::{get_current_time, LiquidWallet, MannaError, Network};

use boltz_client::boltz::GetQuoteResponse;
use boltz_client::{
    bitcoin::consensus::{encode::deserialize_hex, serialize}, boltz::{
        ChainSwapStates, Cooperative, CreateReverseRequest, CreateReverseResponse,
        CreateSubmarineRequest, CreateSubmarineResponse, RevSwapStates, Side, SubSwapStates,
        Webhook,
    }, elements::{encode::deserialize, hashes::hex::DisplayHex, Transaction}, network::{
        electrum::{ElectrumBitcoinClient, ElectrumLiquidClient}, BitcoinClient,
        LiquidClient,
    }, swaps::{magic_routing, SwapScriptCommon}, util::secrets::{Preimage, SwapMasterKey}, Bolt11Invoice, BtcSwapScript,
    BtcSwapTx,
    Keypair,
    LBtcSwapScript,
    LBtcSwapTx,
    Serialize,
    ToHex,
};
use lwk_wollet::ElectrumOptions;
use std::str::FromStr;

impl SubmarineSwap {
    fn get_lbtc_script(&self, swap_data: &Swap) -> Result<LBtcSwapScript, BoltzError> {
        if self.from == Chain::Liquid {
            let swap_res: CreateSubmarineResponse = self.swap_create_res.clone().try_into()?;
            let keys: Keypair = self.keys.clone().try_into()?;
            let our_pub_key = keys.public_key().into();
            let script = LBtcSwapScript::submarine_from_swap_resp(&swap_res, our_pub_key)?;
            script
                .validate_address(swap_data.network.liquid(), swap_res.address.clone())
                .map_err(BoltzError::from)?;
            Ok(script)
        } else {
            Err(BoltzError::new(
                "Invalid data".to_string(),
                "getLbtcScript called on bitcoin swap!".to_string(),
            ))
        }
    }

    fn get_btc_script(&self, swap_data: &Swap) -> Result<BtcSwapScript, BoltzError> {
        if self.from == Chain::Bitcoin {
            let swap_res: CreateSubmarineResponse = self.swap_create_res.clone().try_into()?;
            let keys: Keypair = self.keys.clone().try_into()?;
            let our_pub_key = keys.public_key().into();
            let script = BtcSwapScript::submarine_from_swap_resp(&swap_res, our_pub_key)?;
            script
                .validate_address(swap_data.network.bitcoin(), swap_res.address.clone())
                .map_err(BoltzError::from)?;
            Ok(script)
        } else {
            Err(BoltzError::new(
                "Invalid data".to_string(),
                "getLbtcScript called on liquid swap!".to_string(),
            ))
        }
    }
}

impl ReverseSwap {
    fn get_lbtc_script(&self, swap_data: &Swap) -> Result<LBtcSwapScript, BoltzError> {
        if self.to == Chain::Liquid {
            let swap_res: CreateReverseResponse = self.swap_create_res.clone().try_into()?;
            let keys: Keypair = self.keys.clone().try_into()?;
            let our_pub_key = keys.public_key().into();
            let script = LBtcSwapScript::reverse_from_swap_resp(&swap_res, our_pub_key)?;
            script
                .validate_address(swap_data.network.liquid(), swap_res.lockup_address.clone())
                .map_err(BoltzError::from)?;
            Ok(script)
        } else {
            Err(BoltzError::new(
                "Invalid data".to_string(),
                "getLbtcScript called on bitcoin swap!".to_string(),
            ))
        }
    }

    fn get_btc_script(&self, swap_data: &Swap) -> Result<BtcSwapScript, BoltzError> {
        if self.to == Chain::Bitcoin {
            let swap_res: CreateReverseResponse = self.swap_create_res.clone().try_into()?;
            let keys: Keypair = self.keys.clone().try_into()?;
            let our_pub_key = keys.public_key().into();
            let script = BtcSwapScript::reverse_from_swap_resp(&swap_res, our_pub_key)?;
            script
                .validate_address(swap_data.network.bitcoin(), swap_res.lockup_address.clone())
                .map_err(BoltzError::from)?;
            Ok(script)
        } else {
            Err(BoltzError::new(
                "Invalid data".to_string(),
                "getLbtcScript called on liquid swap!".to_string(),
            ))
        }
    }
}

impl ChainSwap {
    pub(crate) fn get_scripts(
        &self,
        swap_data: &Swap,
    ) -> Result<(BtcSwapScript, LBtcSwapScript), BoltzError> {
        let claim_keys: Keypair = self.claim_keys.clone().try_into()?;
        let claim_pub_key = claim_keys.public_key().into();
        let refund_keys: Keypair = self.refund_keys.clone().try_into()?;
        let refund_pub_key = refund_keys.public_key().into();

        if self.direction == ChainSwapDirection::BtcToLbtc {
            let lockup_script = BtcSwapScript::chain_from_swap_resp(
                Side::Lockup,
                self.lockup_details.clone().try_into()?,
                refund_pub_key,
            )?;

            lockup_script
                .validate_address(
                    swap_data.network.bitcoin(),
                    self.lockup_details.clone().lockup_address,
                )
                .map_err(BoltzError::from)?;

            let claim_script = LBtcSwapScript::chain_from_swap_resp(
                Side::Claim,
                self.claim_details.clone().try_into()?,
                claim_pub_key,
            )?;
            Ok((lockup_script, claim_script))
        } else {
            let lockup_script = LBtcSwapScript::chain_from_swap_resp(
                Side::Lockup,
                self.lockup_details.clone().try_into()?,
                refund_pub_key,
            )?;

            lockup_script
                .validate_address(
                    swap_data.network.liquid(),
                    self.lockup_details.clone().lockup_address,
                )
                .map_err(|_| {
                    BoltzError::new(
                        "Address".to_string(),
                        "Lockup address mismatch!".to_string(),
                    )
                })?;

            let claim_script = BtcSwapScript::chain_from_swap_resp(
                Side::Claim,
                self.claim_details.clone().try_into()?,
                claim_pub_key,
            )?;
            Ok((claim_script, lockup_script))
        }
    }
}

pub(crate) fn get_electrum_liquid_client(
    api_config: &ApiConfig,
    network: Network,
) -> Result<ElectrumLiquidClient, BoltzError> {
    let client = api_config
        .get_electrum_url(&network, &Chain::Liquid)?
        .build_client(&ElectrumOptions { timeout: Some(10) })
        .map_err(|e| BoltzError::new("Electrum".to_string(), e.to_string()))?;
    Ok(ElectrumLiquidClient::from_client(client, network.liquid()))
}

pub(crate) fn get_electrum_bitcoin_client(
    api_config: &ApiConfig,
    network: Network,
) -> Result<ElectrumBitcoinClient, BoltzError> {
    let client = api_config
        .get_electrum_url(&network, &Chain::Bitcoin)?
        .build_client(&ElectrumOptions { timeout: Some(10) })
        .map_err(|e| BoltzError::new("Electrum".to_string(), e.to_string()))?;
    Ok(ElectrumBitcoinClient::from_client(
        client,
        network.bitcoin(),
    ))
}

impl BoltzManager {
    /// Submarine swap
    /// Chain -> Lightning
    /// invoice is either bolt11 or bolt12 invoice
    pub async fn new_submarine(
        self,
        wallet: LiquidWallet,
        index: u64,
        network: Network,
        from: Chain,
        invoice: String,
        note: Option<String>,
        extra_swap_fee: Option<ExtraSwapFee>,
        web_hook: Option<WebHook>,
    ) -> Result<Swap, BoltzError> {
        let signed_index: i64 = index.try_into().map_err(|_| {
            BoltzError::new(
                "Casting".to_string(),
                "overflow while casting u64 to i64".to_string(),
            )
        })?;
        let swap_master_key =
            SwapMasterKey::from_mnemonic(&wallet.swap_mnemonic, None, network.into())?;
        let refund_keypair = match from {
            Chain::Bitcoin => swap_master_key.derive_swapkey(index),
            Chain::Liquid => swap_master_key.derive_liquid_swapkey(index),
        }?;

        let boltz_client = self.api_config.get_boltz_client(&network);
        let submarine_pair = boltz_client.get_submarine_pairs().await?;
        let pair = match from {
            Chain::Bitcoin => submarine_pair.get_btc_to_btc_pair(),
            Chain::Liquid => submarine_pair.get_lbtc_to_btc_pair(),
        };

        // Create swap request
        let create_swap_req = CreateSubmarineRequest {
            from: match from {
                Chain::Bitcoin => "BTC",
                Chain::Liquid => "L-BTC",
            }
            .to_string(),
            to: "BTC".to_string(),
            invoice: invoice.clone(),
            referral_id: Some("Manna".to_string()),
            refund_public_key: refund_keypair.public_key().into(),
            pair_hash: pair.clone().map(|pair| pair.hash),
            extra_fees: extra_swap_fee.map(Into::into),
            webhook: web_hook.map(Webhook::from),
        };

        let swap_res = boltz_client.post_swap_req(&create_swap_req).await?;

        // Extract amount and preimage - try BOLT11 first, fallback to BOLT12
        let (receive_amount, preimage) = match Bolt11Invoice::from_str(&invoice) {
            Ok(bolt11_invoice) => {
                // Validate response for bolt11 invoice
                swap_res.validate(
                    &invoice,
                    &refund_keypair.public_key().into(),
                    network.to_chain(from),
                )?;

                let amount: u64 = bolt11_invoice.amount_milli_satoshis().unwrap_or(0) / 1000;
                let preimage: PreImage =
                    Preimage::from_sha256_str(&bolt11_invoice.payment_hash().to_string())?.into();
                (amount, preimage)
            }
            Err(_) => match parse_bolt12_invoice(invoice.clone()) {
                Ok(bolt12_invoice) => {
                    let amount: u64 = bolt12_invoice.amount_msats() / 1000;
                    let preimage: PreImage =
                        Preimage::from_sha256_str(&bolt12_invoice.payment_hash().to_string())?
                            .into();
                    (amount, preimage)
                }
                Err(_) => {
                    return Err(BoltzError::new(
                        "invoice".to_string(),
                        "Invalid invoice format".to_string(),
                    ));
                }
            },
        };

        let swap_data = Swap {
            id: swap_res.id.clone(),
            index: signed_index,
            wallet_id: wallet.uuid,
            wallet_type: wallet.wallet_type,
            network,
            preimage,
            send_amount: swap_res.expected_amount,
            receive_amount,
            creation_time: get_current_time(),
            completion_time: None,

            submarine: Some(SubmarineSwap {
                from,
                keys: refund_keypair.into(),
                invoice,
                swap_create_res: SubmarineResponse::from(swap_res),
            }),
            reverse: None,
            chain: None,

            swap_status: SubSwapStates::Created.to_string(),
            failure_reason: None,

            note,
            boltz_fee: pair
                .clone()
                .map(|p| (receive_amount as f64 * p.fees.percentage / 100.0).ceil() as u64),
            lockup_fee: Some(0),
            claim_fee: pair.map(|p| p.fees.miner_fees),

            refunded_address: None,
            refund_fee: None,
            transactions: Vec::new(),
            is_exchange_swap: false,
            expected_lockup_amount: None,
        };
        Ok(swap_data)
    }

    /// Reverse swap
    /// Lightning -> Chain,
    /// pass amount and note or bolt12_invoice,
    /// address signature is optional and defaults to schnorr signature with claim key, pass it in case of bolt12 signed by signing key
    pub async fn new_reverse(
        self,
        wallet: LiquidWallet,
        network: Network,
        to: Chain,
        address: Option<String>,
        address_signature: Option<String>,
        amount: Option<u64>,
        index: u64,
        note: Option<String>,
        extra_swap_fee: Option<ExtraSwapFee>,
        web_hook: Option<WebHook>,
        bolt12_invoice: Option<String>,
    ) -> Result<Swap, BoltzError> {
        let signed_index: i64 = index.try_into().map_err(|_| {
            BoltzError::new(
                "Casting".to_string(),
                "overflow while casting u64 to i64".to_string(),
            )
        })?;
        let send_amount = if let Some(bolt12_invoice) = bolt12_invoice.clone() {
            decode_bolt12_invoice(bolt12_invoice)?.msats / 1000
        } else {
            amount.unwrap_or(0)
        };
        let swap_master_key =
            SwapMasterKey::from_mnemonic(&wallet.swap_mnemonic, None, network.into())?;
        let claim_keypair = match to {
            Chain::Bitcoin => swap_master_key.derive_swapkey(index),
            Chain::Liquid => swap_master_key.derive_swapkey(index),
        }?;
        let claim_pubkey = claim_keypair.public_key().into();
        let preimage = Preimage::from_swap_key(&claim_keypair.clone());

        let boltz_client = self.api_config.get_boltz_client(&network);
        let reverse_pair = boltz_client.get_reverse_pairs().await?;
        let pair = match to {
            Chain::Bitcoin => reverse_pair.get_btc_to_btc_pair(),
            Chain::Liquid => reverse_pair.get_btc_to_lbtc_pair(),
        };

        let create_reverse_req = CreateReverseRequest {
            from: "BTC".to_string(),
            to: match to {
                Chain::Bitcoin => "BTC",
                Chain::Liquid => "L-BTC",
            }
            .to_string(),
            preimage_hash: if bolt12_invoice.is_none() {
                Some(preimage.sha256)
            } else {
                None
            },
            claim_public_key: claim_pubkey,
            address: address.clone(),
            address_signature: address_signature.or(address
                .map(|a| magic_routing::sign_address(&a, &claim_keypair).ok())
                .flatten()
                .map(|s| s.to_string())),
            invoice: bolt12_invoice.clone(),
            invoice_amount: amount,
            referral_id: Some("Manna".to_string()),
            description: note.clone(),
            description_hash: None,
            extra_fees: extra_swap_fee.clone().map(Into::into),
            webhook: web_hook.map(Webhook::from),
        };

        let swap_res = boltz_client.post_reverse_req(create_reverse_req).await?;
        // validate API data
        swap_res.validate(&preimage, &claim_pubkey, network.to_chain(to))?;

        let claim_fee = pair.clone().map(|p| p.fees.miner_fees.claim);
        let mut swap_create_res = ReverseResponse::from(swap_res.clone());
        if swap_create_res.invoice.is_none() && bolt12_invoice.is_some() {
            swap_create_res.invoice = bolt12_invoice;
        }

        Ok(Swap {
            id: swap_res.id,
            index: signed_index,
            wallet_id: wallet.uuid,
            wallet_type: wallet.wallet_type,
            network,
            preimage: preimage.into(),
            send_amount,
            receive_amount: swap_res.onchain_amount - claim_fee.unwrap_or_default(),
            creation_time: get_current_time(),
            completion_time: None,

            submarine: None,
            reverse: Some(ReverseSwap {
                to,
                keys: claim_keypair.into(),
                swap_create_res,
            }),
            chain: None,

            swap_status: RevSwapStates::Created.to_string(),
            failure_reason: None,

            note,
            boltz_fee: pair
                .clone()
                .map(|p| (send_amount as f64 * p.fees.percentage / 100.0).ceil() as u64),
            lockup_fee: pair.clone().map(|p| p.fees.miner_fees.lockup),
            claim_fee,

            refunded_address: None,
            refund_fee: None,
            transactions: Vec::new(),
            is_exchange_swap: false,
            expected_lockup_amount: None,
        })
    }

    /// Chain swaps
    pub async fn new_chain(
        self,
        wallet: LiquidWallet,
        network: Network,
        direction: ChainSwapDirection,
        index: u64,
        amount: u64,
        note: Option<String>,
        extra_swap_fee: Option<ExtraSwapFee>,
        web_hook: Option<WebHook>,
    ) -> Result<Swap, BoltzError> {
        let signed_index: i64 = index.try_into().map_err(|_| {
            BoltzError::new(
                "Casting".to_string(),
                "overflow while casting u64 to i64".to_string(),
            )
        })?;
        let swap_master_key =
            SwapMasterKey::from_mnemonic(&wallet.swap_mnemonic, None, network.into())?;

        let refund_keypair = match direction {
            ChainSwapDirection::BtcToLbtc => swap_master_key.derive_swapkey(index),
            ChainSwapDirection::LbtcToBtc => swap_master_key.derive_liquid_swapkey(index),
        }?;
        let refund_public_key = refund_keypair.public_key().into();

        let claim_keypair: Keypair = match direction {
            ChainSwapDirection::BtcToLbtc => swap_master_key.derive_liquid_swapkey(index + 1),
            ChainSwapDirection::LbtcToBtc => swap_master_key.derive_swapkey(index + 1),
        }?;
        let claim_public_key = claim_keypair.public_key().into();
        let preimage = Preimage::from_swap_key(&claim_keypair.clone());

        let boltz_client = self.api_config.get_boltz_client(&network);
        let chain_pair = boltz_client.get_chain_pairs().await?;
        let pair = match direction {
            ChainSwapDirection::BtcToLbtc => chain_pair.get_btc_to_lbtc_pair(),
            ChainSwapDirection::LbtcToBtc => chain_pair.get_lbtc_to_btc_pair(),
        };

        let create_swap_req = boltz_client::swaps::boltz::CreateChainRequest {
            from: match direction {
                ChainSwapDirection::BtcToLbtc => "BTC",
                ChainSwapDirection::LbtcToBtc => "L-BTC",
            }
            .to_string(),
            to: match direction {
                ChainSwapDirection::BtcToLbtc => "L-BTC",
                ChainSwapDirection::LbtcToBtc => "BTC",
            }
            .to_string(),
            preimage_hash: preimage.sha256,
            claim_public_key: Some(claim_public_key),
            refund_public_key: Some(refund_public_key),
            referral_id: Some("Manna".to_string()),
            user_lock_amount: Some(amount),
            server_lock_amount: None,
            pair_hash: pair.clone().map(|p| p.hash),
            extra_fees: extra_swap_fee.clone().map(Into::into),
            webhook: web_hook.map(Webhook::from),
        };

        let swap_res = boltz_client.post_chain_req(create_swap_req).await?;

        // validate API data
        swap_res.validate(
            &claim_public_key,
            &refund_public_key,
            network.to_chain(match direction {
                ChainSwapDirection::BtcToLbtc => Chain::Bitcoin,
                ChainSwapDirection::LbtcToBtc => Chain::Liquid,
            }),
            network.to_chain(match direction {
                ChainSwapDirection::BtcToLbtc => Chain::Liquid,
                ChainSwapDirection::LbtcToBtc => Chain::Bitcoin,
            }),
        )?;

        let claim_fee = pair.clone().map(|p| p.fees.miner_fees.user.claim);
        Ok(Swap {
            id: swap_res.id.clone(),
            index: signed_index,
            wallet_id: wallet.uuid,
            wallet_type: wallet.wallet_type,
            network,
            preimage: preimage.into(),
            send_amount: swap_res.lockup_details.amount,
            receive_amount: swap_res.claim_details.amount - claim_fee.unwrap_or(0),
            creation_time: get_current_time(),
            completion_time: None,

            submarine: None,
            reverse: None,
            chain: Some(ChainSwap {
                direction,
                refund_keys: refund_keypair.into(),
                claim_keys: claim_keypair.into(),
                lockup_details: swap_res.clone().lockup_details.into(),
                claim_details: swap_res.clone().claim_details.into(),
            }),

            swap_status: ChainSwapStates::Created.to_string(),
            failure_reason: None,

            note,
            boltz_fee: pair.clone().map(|p| {
                (swap_res.lockup_details.amount as f64 * p.fees.percentage / 100.0).ceil() as u64
            }),
            lockup_fee: pair.clone().map(|p| p.fees.miner_fees.server),
            claim_fee,

            refunded_address: None,
            refund_fee: None,
            transactions: Vec::new(),
            is_exchange_swap: false,
            expected_lockup_amount: None,
        })
    }

    /// close the swap by letting boltz claim the locked up coins.
    pub async fn close_submarine_coop(&self, swap: &Swap) -> Result<(), BoltzError> {
        if swap.submarine.is_none() {
            return Err(BoltzError::new(
                "Invalid swap".to_string(),
                "Expected submarine swap".to_string(),
            ));
        }
        let submarine = swap.submarine.clone().unwrap();
        let boltz_client = self.api_config.get_boltz_client(&swap.network);
        let claim_tx_response = boltz_client
            .get_submarine_claim_tx_details(&swap.id)
            .await?;

        if !Preimage::from_str(&claim_tx_response.preimage)?
            .sha256
            .to_string()
            .eq(&swap.preimage.sha256.to_string())
        {
            return Err(BoltzError::new(
                "Invalid API data".to_string(),
                "Boltz provided invalid preimage".to_string(),
            ));
        }

        let keys: Keypair = submarine.keys.clone().try_into()?;
        let musig = match submarine.from {
            Chain::Bitcoin => submarine.get_btc_script(&swap)?.partial_sign(
                &keys,
                &claim_tx_response.pub_nonce,
                &claim_tx_response.transaction_hash,
            ),
            Chain::Liquid => submarine.get_lbtc_script(&swap)?.partial_sign(
                &keys,
                &claim_tx_response.pub_nonce,
                &claim_tx_response.transaction_hash,
            ),
        }?;

        boltz_client
            .post_submarine_claim_tx_details(&swap.id, musig.1, musig.0)
            .await?;

        Ok(())
    }

    /// if for some reason boltz fails to lockup funds or if the amount sent is not satisfactory.
    /// call the function to refund the locked up funds.
    /// returns refund transaction byte string
    pub async fn refund_submarine(
        &self,
        swap: &Swap,
        refund_address: &String,
        miner_fee: TxFee,
        try_cooperate: bool,
    ) -> Result<String, BoltzError> {
        if swap.submarine.is_none() {
            return Err(BoltzError::new(
                "Invalid swap".to_string(),
                "Expected submarine swap".to_string(),
            ));
        }
        let submarine = swap.submarine.clone().unwrap();
        let id = swap.id.clone();
        let keys: Keypair = submarine.keys.clone().try_into()?;
        let boltz_client = self.api_config.get_boltz_client(&swap.network);

        if submarine.from == Chain::Liquid {
            let liquid_client = get_electrum_liquid_client(&self.api_config, swap.network)?;
            let script: LBtcSwapScript = submarine.get_lbtc_script(&swap)?;
            let tx = LBtcSwapTx::new_refund(
                script.clone(),
                refund_address,
                &liquid_client,
                &boltz_client,
                id.clone(),
            )
            .await?;
            let cooperative = if try_cooperate {
                Some(Cooperative {
                    boltz_api: &boltz_client,
                    swap_id: id,
                    signature: None,
                })
            } else {
                None
            };
            let signed = tx
                .sign_refund(&keys, miner_fee.into(), cooperative, true)
                .await?;

            Ok(signed.serialize().to_lower_hex_string())
        } else {
            let bitcoin_client = get_electrum_bitcoin_client(&self.api_config, swap.network)?;
            let script = submarine.get_btc_script(&swap)?;
            let script_balance = script.get_balance(&bitcoin_client).await?;

            if script_balance.0 > 0 || script_balance.1 > 0 {
                let tx = BtcSwapTx::new_refund(
                    script.clone(),
                    refund_address,
                    &bitcoin_client,
                    &boltz_client,
                    id.clone(),
                )
                .await?;
                let cooperative = if try_cooperate {
                    Some(Cooperative {
                        boltz_api: &boltz_client,
                        swap_id: id.clone(),
                        signature: None,
                    })
                } else {
                    None
                };
                let signed = tx.sign_refund(&keys, miner_fee.into(), cooperative).await?;
                Ok(signed.serialize().to_lower_hex_string())
            } else {
                Err(BoltzError::new(
                    "NoData".to_string(),
                    "Lockup transaction is not yet found.".to_string(),
                ))
            }
        }
    }

    /// claim the reverse swap once its status is transaction.confirmed and boltz's lockup tx is
    /// included in the block the function doesn't check confirmation on lockup tx.
    pub async fn claim_reverse(
        &self,
        swap: &Swap,
        claim_address: &String,
        miner_fee: TxFee,
        try_cooperate: bool,
    ) -> Result<String, BoltzError> {
        if swap.reverse.is_none() {
            return Err(BoltzError::new(
                "Invalid swap".to_string(),
                "Expected reverse swap".to_string(),
            ));
        }
        let reverse = swap.reverse.clone().unwrap();

        let id = swap.id.clone();
        let keys: Keypair = reverse.keys.clone().try_into()?;
        let preimage = swap.preimage.clone().try_into()?;
        let boltz_client = self.api_config.get_boltz_client(&swap.network);

        if reverse.to == Chain::Liquid {
            let script = reverse.get_lbtc_script(&swap)?;
            let liquid_client = get_electrum_liquid_client(&self.api_config, swap.network)?;
            let tx = LBtcSwapTx::new_claim(
                script.clone(),
                claim_address.to_string(),
                &liquid_client,
                &boltz_client,
                id.clone(),
            )
            .await?;
            let cooperative = if try_cooperate {
                Some(Cooperative {
                    boltz_api: &boltz_client,
                    swap_id: id.clone(),
                    signature: None,
                })
            } else {
                None
            };
            let signed = tx
                .sign_claim(&keys, &preimage, miner_fee.into(), cooperative, true)
                .await?;

            Ok(signed.serialize().to_lower_hex_string())
        } else {
            let script = reverse.get_btc_script(&swap)?;
            let bitcoin_client = get_electrum_bitcoin_client(&self.api_config, swap.network)?;
            let script_balance = script.get_balance(&bitcoin_client).await?;
            if script_balance.0 > 0 || script_balance.1 > 0 {
                let tx = BtcSwapTx::new_claim(
                    script.clone(),
                    claim_address.to_string(),
                    &bitcoin_client,
                    &boltz_client,
                    id.clone(),
                )
                .await?;
                let cooperative = if try_cooperate {
                    Some(Cooperative {
                        boltz_api: &boltz_client,
                        swap_id: id.clone(),
                        signature: None,
                    })
                } else {
                    None
                };
                let signed = tx
                    .sign_claim(&keys, &preimage, miner_fee.into(), cooperative)
                    .await?;
                Ok(signed.serialize().to_lower_hex_string())
            } else {
                Err(BoltzError::new(
                    "Not Found".to_string(),
                    "Lockup transaction is not yet found.".to_string(),
                ))
            }
        }
    }

    /// claim chain swap
    pub async fn claim_chain(
        &self,
        swap: &Swap,
        claim_address: &String,
        server_claim_address: &String,
        miner_fee: TxFee,
        try_cooperate: bool,
    ) -> Result<String, BoltzError> {
        if swap.chain.is_none() {
            return Err(BoltzError::new(
                "Invalid swap".to_string(),
                "Expected chain swap".to_string(),
            ));
        }
        let chain = swap.chain.clone().unwrap();

        let id: String = swap.id.clone();
        let network = swap.network;
        let boltz_client = self.api_config.get_boltz_client(&network);

        let btc_electrum_client = get_electrum_bitcoin_client(&self.api_config, network)?;
        let lbtc_electrum_client = get_electrum_liquid_client(&self.api_config, network)?;

        match chain.direction {
            ChainSwapDirection::BtcToLbtc => {
                let (btc_lockup_script, lbtc_claim_script) = chain.get_scripts(&swap)?;
                let claim_tx: LBtcSwapTx = LBtcSwapTx::new_claim(
                    lbtc_claim_script.clone(),
                    claim_address.clone(),
                    &lbtc_electrum_client,
                    &boltz_client,
                    id.clone(),
                )
                .await?;

                let cooperative = if try_cooperate {
                    let refund_tx = BtcSwapTx::new_refund(
                        btc_lockup_script.clone(),
                        server_claim_address,
                        &btc_electrum_client,
                        &boltz_client,
                        id.clone(),
                    )
                    .await?;
                    let claim_tx_response = boltz_client.get_chain_claim_tx_details(&id).await?;
                    if let Some(claim_tx_response) = claim_tx_response {
                        let (partial_sig, pub_nonce) = refund_tx.partial_sign(
                            &chain.refund_keys.clone().try_into()?,
                            &claim_tx_response.pub_nonce,
                            &claim_tx_response.transaction_hash,
                        )?;
                        Some(Cooperative {
                            boltz_api: &boltz_client,
                            swap_id: id,
                            signature: Some((partial_sig, pub_nonce)),
                        })
                    } else {
                        None
                    }
                } else {
                    None
                };
                let signed = claim_tx
                    .sign_claim(
                        &chain.claim_keys.clone().try_into()?,
                        &swap.preimage.clone().try_into()?,
                        miner_fee.into(),
                        cooperative,
                        true,
                    )
                    .await?;
                Ok(signed.serialize().to_lower_hex_string())
            }
            ChainSwapDirection::LbtcToBtc => {
                let (btc_claim_script, lbtc_lockup_script) = chain.get_scripts(&swap)?;
                let claim_tx = BtcSwapTx::new_claim(
                    btc_claim_script.clone(),
                    claim_address.clone(),
                    &btc_electrum_client,
                    &boltz_client,
                    id.clone(),
                )
                .await?;

                let cooperative = if try_cooperate {
                    let refund_tx = LBtcSwapTx::new_refund(
                        lbtc_lockup_script.clone(),
                        server_claim_address,
                        &lbtc_electrum_client,
                        &boltz_client,
                        id.clone(),
                    )
                    .await?;
                    let claim_tx_response = boltz_client.get_chain_claim_tx_details(&id).await?;
                    if let Some(claim_tx_response) = claim_tx_response {
                        let (partial_sig, pub_nonce) = refund_tx.partial_sign(
                            &chain.refund_keys.clone().try_into()?,
                            &claim_tx_response.pub_nonce,
                            &claim_tx_response.transaction_hash,
                        )?;
                        Some(Cooperative {
                            boltz_api: &boltz_client,
                            swap_id: id,
                            signature: Some((partial_sig, pub_nonce)),
                        })
                    } else {
                        None
                    }
                } else {
                    None
                };

                let signed = claim_tx
                    .sign_claim(
                        &chain.claim_keys.clone().try_into()?,
                        &swap.preimage.clone().try_into()?,
                        miner_fee.into(),
                        cooperative,
                    )
                    .await?;
                Ok(serialize(&signed).to_hex())
            }
        }
    }

    /// refund chain swap
    pub async fn refund_chain(
        &self,
        swap: &Swap,
        refund_address: &String,
        miner_fee: TxFee,
        try_cooperate: bool,
    ) -> Result<String, BoltzError> {
        if swap.chain.is_none() {
            return Err(BoltzError::new(
                "Invalid swap".to_string(),
                "Expected chain swap".to_string(),
            ));
        }
        let chain = swap.chain.clone().unwrap();

        let id = swap.id.clone();
        let network = swap.network;
        let boltz_client = self.api_config.get_boltz_client(&network);
        let btc_electrum_client = get_electrum_bitcoin_client(&self.api_config, network)?;
        let lbtc_electrum_client = get_electrum_liquid_client(&self.api_config, network)?;
        let cooperative = if try_cooperate {
            Some(Cooperative {
                boltz_api: &boltz_client,
                swap_id: id.clone(),
                signature: None,
            })
        } else {
            None
        };
        match chain.direction {
            ChainSwapDirection::BtcToLbtc => {
                let (btc_lockup_script, _) = chain.get_scripts(&swap)?;
                let refund_tx = BtcSwapTx::new_refund(
                    btc_lockup_script.clone(),
                    refund_address,
                    &btc_electrum_client,
                    &boltz_client,
                    id.clone(),
                )
                .await?;
                let signed = refund_tx
                    .sign_refund(
                        &chain.refund_keys.clone().try_into()?,
                        miner_fee.into(),
                        cooperative,
                    )
                    .await?;

                Ok(serialize(&signed).to_hex())
            }
            ChainSwapDirection::LbtcToBtc => {
                let (_, lbtc_lockup_script) = chain.get_scripts(&swap)?;
                let refund_tx = LBtcSwapTx::new_refund(
                    lbtc_lockup_script.clone(),
                    refund_address,
                    &lbtc_electrum_client,
                    &boltz_client,
                    id.clone(),
                )
                .await?;
                let signed = refund_tx
                    .sign_refund(
                        &chain.refund_keys.clone().try_into()?,
                        miner_fee.into(),
                        cooperative,
                        false,
                    )
                    .await?;
                Ok(signed.serialize().to_lower_hex_string())
            }
        }
    }

    /// get on-chain swap negotiable value if locked up amount is not according to swap amount
    pub async fn get_chain_swap_quote(&self, swap: &Swap) -> u64 {
        if swap.chain.is_none() {
            return 0;
        }
        self.api_config
            .get_boltz_client(&swap.network)
            .get_quote(&swap.id)
            .await
            .unwrap_or(GetQuoteResponse { amount: 0 })
            .amount
    }

    /// accept on-chain swap quote
    pub async fn accept_chain_swap_quote(
        &self,
        swap: &Swap,
        quote_amount: u64,
    ) -> Result<bool, BoltzError> {
        if swap.chain.is_none() {
            return Ok(false);
        }
        self.api_config
            .get_boltz_client(&swap.network)
            .accept_quote(&swap.id, quote_amount)
            .await?;
        Ok(true)
    }

    /// Broadcast tx using your own electrum server
    pub async fn broadcast_electrum(
        &self,
        network: Network,
        chain: Chain,
        signed_hex: String,
    ) -> Result<String, BoltzError> {
        let txid = match chain {
            Chain::Bitcoin => {
                let transaction =
                    deserialize_hex::<boltz_client::bitcoin::Transaction>(&signed_hex)
                        .map_err(|e| BoltzError::new("HexDecode".to_string(), e.to_string()))?;
                get_electrum_bitcoin_client(&self.api_config, network)?
                    .broadcast_tx(&transaction)
                    .await
                    .map_err(|e| {
                        BoltzError::new(
                            "BroadcastTx".to_string(),
                            format!("Failed to broadcast via electrum (bitcoin): {e}"),
                        )
                    })?
                    .to_string()
            }
            Chain::Liquid => {
                let signed_bytes = hex::decode(&signed_hex)
                    .map_err(|e| BoltzError::new("HexDecode".to_string(), e.to_string()))?;
                let transaction = deserialize::<Transaction>(&signed_bytes)
                    .map_err(|e| BoltzError::new("HexDecode".to_string(), e.to_string()))?;

                get_electrum_liquid_client(&self.api_config, network)?
                    .broadcast_tx(&transaction)
                    .await
                    .map_err(|e| {
                        BoltzError::new(
                            "BroadcastTx".to_string(),
                            format!("Failed to broadcast via electrum (liquid): {e}"),
                        )
                    })?
            }
        };
        Ok(txid)
    }

    /// Broadcast using boltz's electrum server
    pub async fn broadcast_boltz(
        &self,
        chain: Chain,
        network: Network,
        signed_hex: String,
    ) -> Result<String, BoltzError> {
        let tx_res = self
            .api_config
            .get_boltz_client(&network)
            .broadcast_tx(network.to_chain(chain), &signed_hex)
            .await
            .map_err(|e| {
                BoltzError::new(
                    "BroadcastTx".to_string(),
                    format!(
                        "Failed to broadcast via boltz's electrum ({}): {}",
                        match chain {
                            Chain::Bitcoin => "bitcoin",
                            Chain::Liquid => "liquid",
                        },
                        e
                    ),
                )
            })?;

        // Attempt to extract the `id` field directly
        Ok(match tx_res.get("id") {
            Some(id_value) if id_value.is_string() && id_value.as_str().is_some() => {
                Ok(id_value.as_str().unwrap().to_string())
            }
            _ => Err(MannaError::new(
                "TxId not found in boltz response".to_string(),
            )),
        }?)
    }

    /// broadcast signed tx hex to electrum server fallback to boltz for broadcasting, return txID.
    pub async fn broadcast_swap_tx(
        &self,
        tx_hex: String,
        network: Network,
        chain: Chain,
    ) -> Result<String, BoltzError> {
        match self
            .broadcast_electrum(network, chain, tx_hex.clone())
            .await
        {
            Ok(tx_id) => Ok(tx_id),
            Err(_) => self.broadcast_boltz(chain, network, tx_hex).await,
        }
    }
}
