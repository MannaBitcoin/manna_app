use super::error::BoltzError;
use crate::boltz::bolt12::parse_bolt12_invoice;
use crate::boltz::swap_transaction::SwapTransaction;
use crate::util::{ensure_http_prefix, KeyPair, MannaError, Network, WalletType};

use boltz_client::bitcoin::bip32::{DerivationPath, Xpriv, Xpub};
use boltz_client::swaps::magic_routing::check_for_mrh;
use boltz_client::util::secrets::SwapMasterKey;
use boltz_client::{
    bitcoin, bitcoin::Network as bitcoinNetwork, boltz as Internal, fees::Fee, network::{BitcoinChain, Chain as BoltzChain, LiquidChain},
    swaps::{boltz::BoltzApiClientV2, magic_routing::find_magic_routing_hint},
    util::secrets::Preimage,
    Bolt11Invoice,
    Keypair,
    PublicKey,
    Secp256k1,
};
use flutter_rust_bridge::frb;
use lightning::bitcoin::constants::ChainHash;
use lightning::offers::offer::{Amount, Offer};
use lightning::types::string::PrintableString;
use lwk_wollet::ElectrumUrl;
use serde::{Deserialize, Serialize};
use std::{str::FromStr, time::Duration};

#[derive(Clone, Copy, Eq, Serialize, Deserialize, PartialEq, Debug)]
pub enum Chain {
    Bitcoin,
    Liquid,
}

impl Chain {
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            Chain::Bitcoin => "Bitcoin",
            Chain::Liquid => "Liquid",
        }
    }
}

impl Network {
    #[frb(ignore)]
    pub fn to_chain(self, c: Chain) -> BoltzChain {
        match c {
            Chain::Bitcoin => match self {
                Network::Mainnet => BoltzChain::Bitcoin(BitcoinChain::Bitcoin),
                Network::Testnet => BoltzChain::Bitcoin(BitcoinChain::BitcoinTestnet),
                Network::Regtest => BoltzChain::Bitcoin(BitcoinChain::BitcoinRegtest),
            },
            Chain::Liquid => match self {
                Network::Mainnet => BoltzChain::Liquid(LiquidChain::Liquid),
                Network::Testnet => BoltzChain::Liquid(LiquidChain::LiquidTestnet),
                Network::Regtest => BoltzChain::Liquid(LiquidChain::LiquidRegtest),
            },
        }
    }

    #[frb(ignore)]
    pub fn liquid(self) -> LiquidChain {
        match self {
            Network::Mainnet => LiquidChain::Liquid,
            Network::Testnet => LiquidChain::LiquidTestnet,
            Network::Regtest => LiquidChain::LiquidRegtest,
        }
    }

    #[frb(ignore)]
    pub fn bitcoin(self) -> BitcoinChain {
        match self {
            Network::Mainnet => BitcoinChain::Bitcoin,
            Network::Testnet => BitcoinChain::BitcoinTestnet,
            Network::Regtest => BitcoinChain::BitcoinRegtest,
        }
    }
}

impl From<bitcoinNetwork> for Network {
    fn from(value: bitcoinNetwork) -> Self {
        match value {
            bitcoinNetwork::Bitcoin => Network::Mainnet,
            bitcoinNetwork::Testnet | bitcoinNetwork::Testnet4 => Network::Testnet,
            bitcoinNetwork::Regtest => Network::Regtest,
            _ => Network::Mainnet,
        }
    }
}

impl From<Network> for boltz_client::network::Network {
    fn from(value: Network) -> Self {
        match value {
            Network::Mainnet => boltz_client::network::Network::Mainnet,
            Network::Testnet => boltz_client::network::Network::Testnet,
            Network::Regtest => boltz_client::network::Network::Regtest,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Serialize, Deserialize, Debug)]
pub struct TxFee {
    pub absolute: Option<u64>,
    pub relative: Option<f64>,
}

impl From<TxFee> for Fee {
    fn from(value: TxFee) -> Self {
        if let Some(abs) = value.absolute {
            Fee::Absolute(abs)
        } else {
            Fee::Relative(value.relative.unwrap_or(0.0))
        }
    }
}

#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub enum ChainSwapDirection {
    BtcToLbtc,
    LbtcToBtc,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreImage {
    pub value: String,
    pub sha256: String,
    pub hash160: String,
}

impl PreImage {
    pub fn generate(key_pair: KeyPair) -> Result<Self, BoltzError> {
        let key_pair: Keypair = key_pair.try_into()?;
        Ok(Preimage::from_swap_key(&key_pair).into())
    }

    pub fn from_string(preimage: &str) -> Result<Self, BoltzError> {
        let preimage = Preimage::from_str(preimage)?;
        Ok(PreImage {
            value: preimage.to_string().unwrap(),
            sha256: preimage.sha256.to_string(),
            hash160: preimage.hash160.to_string(),
        })
    }
}

impl TryInto<Preimage> for PreImage {
    type Error = BoltzError;

    fn try_into(self) -> Result<Preimage, Self::Error> {
        if !self.value.is_empty() {
            Ok(Preimage::from_str(&self.value)?)
        } else {
            Ok(Preimage::from_sha256_str(&self.sha256)?)
        }
    }
}

impl From<Preimage> for PreImage {
    fn from(value: Preimage) -> Self {
        PreImage {
            value: value.to_string().unwrap_or("".to_string()),
            sha256: value.sha256.to_string(),
            hash160: value.hash160.to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct DecodedInvoice {
    pub msats: u64,
    pub expires_at: u128,
    pub is_expired: bool,
    pub network: Network,
    // address and amount
    pub bip21: Option<(String, u64)>,
    pub preimage_hash: String,
    pub description: Option<String>,

    /// bolt12 offer issuer
    pub issuer: Option<String>,
}

#[frb(sync)]
/// parses bolt11 invoice, if you want to extract bip21 address used to create this lightning invoice use [Self::from_bolt11_invoice] instead.
pub fn decode_bolt11_invoice(invoice: String) -> Result<DecodedInvoice, BoltzError> {
    let inv = Bolt11Invoice::from_str(&invoice)
        .map_err(|e| BoltzError::new("Input".to_string(), e.to_string()))?;
    let millis_since_epoch = std::time::UNIX_EPOCH
        .elapsed()
        .map_err(|e| BoltzError::new("Rust".to_string(), e.to_string()))?;

    Ok(DecodedInvoice {
        expires_at: inv
            .expires_at()
            .unwrap_or(Duration::from_secs(0))
            .as_millis(),
        is_expired: millis_since_epoch >= inv.expires_at().unwrap_or(Duration::from_secs(0)),
        msats: inv.amount_milli_satoshis().unwrap_or(0),
        network: inv.network().into(),
        bip21: None,
        preimage_hash: inv.payment_hash().to_string(),
        description: Some(inv.description().to_string()),
        issuer: None,
    })
}

/// boltz can not create submarine swap paying lightning invoice created by reverse swap.
/// so Pass boltz_url to fetch bip21 address which is encoded by sender and which you can directly pay
pub async fn decode_bolt11_invoice_bip21(
    invoice: String,
    boltz_url: Option<String>,
) -> Result<DecodedInvoice, BoltzError> {
    let inv = Bolt11Invoice::from_str(&invoice)
        .map_err(|e| BoltzError::new("Input".to_string(), e.to_string()))?;

    let bip21 = if let Some(boltz_url) = boltz_url {
        if let Some(_mrh) = find_magic_routing_hint(&invoice)? {
            let boltz_client = BoltzApiClientV2::new(ensure_http_prefix(&boltz_url), None);
            let network: Network = inv.network().into();
            let bip21 =
                check_for_mrh(&boltz_client, &invoice, network.to_chain(Chain::Liquid)).await?;
            bip21.map(|(address, amount)| (address, amount.to_sat()))
        } else {
            None
        }
    } else {
        None
    };

    let millis_since_epoch = std::time::UNIX_EPOCH
        .elapsed()
        .map_err(|e| BoltzError::new("Rust".to_string(), e.to_string()))?;

    Ok(DecodedInvoice {
        expires_at: inv
            .expires_at()
            .unwrap_or(Duration::from_secs(0))
            .as_millis(),
        is_expired: millis_since_epoch >= inv.expires_at().unwrap_or(Duration::from_secs(0)),
        msats: inv.amount_milli_satoshis().unwrap_or(0),
        network: inv.network().into(),
        bip21,
        preimage_hash: inv.payment_hash().to_string(),
        description: Some(inv.description().to_string()),
        issuer: None,
    })
}

#[frb(sync)]
pub fn decode_bolt12_invoice(invoice: String) -> Result<DecodedInvoice, BoltzError> {
    let inv = parse_bolt12_invoice(invoice)?;
    Ok(DecodedInvoice {
        msats: inv.amount_msats(),
        expires_at: inv.relative_expiry().as_millis(),
        is_expired: inv.is_expired(),
        network: if inv.chain() == ChainHash::BITCOIN {
            Network::Mainnet
        } else if inv.chain() == ChainHash::TESTNET4 {
            Network::Testnet
        } else {
            Network::Regtest
        },
        bip21: None,
        preimage_hash: inv.payment_hash().to_string(),
        description: inv.payer_note().map(|s: PrintableString| s.to_string()),
        issuer: inv.issuer().map(|s: PrintableString| s.to_string()),
    })
}

#[derive(Debug, Clone)]
pub struct DecodedBolt12Offer {
    pub id: String,
    pub parsed_offer: String,
    pub is_expired: bool,
    pub networks: Vec<Network>,
    pub amount: Option<u64>,
    pub description: Option<String>,
    pub issuer: Option<String>,
}

/// function to validate bolt12 lightning offer
pub fn decode_bolt12_offer(offer: String) -> Result<DecodedBolt12Offer, MannaError> {
    let offer = offer
        .parse::<Offer>()
        .map_err(|e| MannaError::new(format!("Failed to parse Offer: {:?}", e)))?;

    Ok(DecodedBolt12Offer {
        id: offer.id().to_string(),
        parsed_offer: offer.to_string(),
        is_expired: offer.is_expired(),
        networks: offer
            .chains()
            .iter()
            .map(|e| match e {
                &ChainHash::BITCOIN => Network::Mainnet,
                &ChainHash::TESTNET4 => Network::Testnet,
                _ => Network::Regtest,
            })
            .collect(),
        amount: offer
            .amount()
            .map(|a| match a {
                Amount::Bitcoin { amount_msats } => Some(amount_msats),
                Amount::Currency { .. } => None,
            })
            .flatten(),
        description: offer.description().map(|s| s.to_string()),
        issuer: offer.issuer().map(|s| s.to_string()),
    })
}
/// mirrors

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeafData {
    pub output: String,
    pub version: u8,
}

impl From<LeafData> for Internal::Leaf {
    fn from(value: LeafData) -> Self {
        Internal::Leaf {
            output: value.output,
            version: value.version,
        }
    }
}

impl From<Internal::Leaf> for LeafData {
    fn from(leaf: Internal::Leaf) -> Self {
        LeafData {
            output: leaf.output,
            version: leaf.version,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapTreeData {
    #[serde(rename = "claimLeaf")]
    pub claim_leaf: LeafData,
    #[serde(rename = "refundLeaf")]
    pub refund_leaf: LeafData,
}

impl From<SwapTreeData> for Internal::SwapTree {
    fn from(value: SwapTreeData) -> Self {
        Internal::SwapTree {
            claim_leaf: value.claim_leaf.into(),
            refund_leaf: value.refund_leaf.into(),
        }
    }
}

impl From<Internal::SwapTree> for SwapTreeData {
    fn from(tree: Internal::SwapTree) -> Self {
        SwapTreeData {
            claim_leaf: tree.claim_leaf.into(),
            refund_leaf: tree.refund_leaf.into(),
        }
    }
}

#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainSwapData {
    pub swap_tree: SwapTreeData,
    pub lockup_address: String,
    pub server_public_key: String,
    pub timeout_block_height: u32,
    pub amount: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blinding_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub refund_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub claim_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bip21: Option<String>,
}

impl TryInto<Internal::ChainSwapDetails> for ChainSwapData {
    type Error = BoltzError;

    fn try_into(self) -> Result<Internal::ChainSwapDetails, Self::Error> {
        let sender_pubkey =
            PublicKey::from_str(&self.server_public_key).map_err(BoltzError::from)?;
        Ok(Internal::ChainSwapDetails {
            swap_tree: self.swap_tree.into(),
            lockup_address: self.lockup_address,
            server_public_key: sender_pubkey,
            timeout_block_height: self.timeout_block_height,
            amount: self.amount,
            blinding_key: self.blinding_key,
            refund_address: self.refund_address,
            claim_address: self.claim_address,
            bip21: self.bip21,
        })
    }
}

impl From<Internal::ChainSwapDetails> for ChainSwapData {
    fn from(detail: Internal::ChainSwapDetails) -> Self {
        ChainSwapData {
            swap_tree: detail.swap_tree.into(),
            lockup_address: detail.lockup_address,
            server_public_key: detail.server_public_key.to_string(),
            timeout_block_height: detail.timeout_block_height,
            amount: detail.amount,
            blinding_key: detail.blinding_key,
            refund_address: detail.refund_address,
            claim_address: detail.claim_address,
            bip21: detail.bip21,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubmarineResponse {
    pub accept_zero_conf: bool,
    pub address: String,
    pub bip21: String,
    pub claim_public_key: String,
    pub expected_amount: u64,
    pub swap_tree: SwapTreeData,
    pub timeout_block_height: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blinding_key: Option<String>,
}

impl From<Internal::CreateSubmarineResponse> for SubmarineResponse {
    fn from(res: Internal::CreateSubmarineResponse) -> Self {
        SubmarineResponse {
            accept_zero_conf: res.accept_zero_conf,
            address: res.address,
            bip21: res.bip21,
            claim_public_key: res.claim_public_key.to_string(),
            expected_amount: res.expected_amount,
            swap_tree: res.swap_tree.into(),
            timeout_block_height: res.timeout_block_height,
            blinding_key: res.blinding_key,
        }
    }
}

impl TryInto<Internal::CreateSubmarineResponse> for SubmarineResponse {
    type Error = BoltzError;

    fn try_into(self) -> Result<Internal::CreateSubmarineResponse, Self::Error> {
        Ok(Internal::CreateSubmarineResponse {
            accept_zero_conf: self.accept_zero_conf,
            address: self.address,
            bip21: self.bip21,
            claim_public_key: PublicKey::from_str(&self.claim_public_key)
                .map_err(BoltzError::from)?,
            expected_amount: self.expected_amount,
            swap_tree: self.swap_tree.into(),
            timeout_block_height: self.timeout_block_height,
            blinding_key: self.blinding_key,
            // this won't be used by caller so it's safe to inject dummy data.
            id: "".to_string(),
            referral_id: None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReverseResponse {
    pub invoice: Option<String>,
    pub swap_tree: SwapTreeData,
    pub lockup_address: String,
    pub refund_public_key: String,
    pub timeout_block_height: u32,
    pub onchain_amount: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blinding_key: Option<String>,
}

impl From<Internal::CreateReverseResponse> for ReverseResponse {
    fn from(res: Internal::CreateReverseResponse) -> Self {
        ReverseResponse {
            invoice: res.invoice,
            swap_tree: res.swap_tree.into(),
            lockup_address: res.lockup_address,
            refund_public_key: res.refund_public_key.to_string(),
            timeout_block_height: res.timeout_block_height,
            onchain_amount: res.onchain_amount,
            blinding_key: res.blinding_key,
        }
    }
}

impl TryInto<Internal::CreateReverseResponse> for ReverseResponse {
    type Error = BoltzError;

    fn try_into(self) -> Result<Internal::CreateReverseResponse, Self::Error> {
        Ok(Internal::CreateReverseResponse {
            invoice: self.invoice,
            swap_tree: self.swap_tree.into(),
            lockup_address: self.lockup_address,
            refund_public_key: PublicKey::from_str(&self.refund_public_key)
                .map_err(BoltzError::from)?,
            timeout_block_height: self.timeout_block_height,
            onchain_amount: self.onchain_amount,
            blinding_key: self.blinding_key,
            // this won't be used by caller so it's safe to inject dummy data.
            id: "".to_string(),
        })
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct ExtraSwapFee {
    pub id: String,
    pub percentage: f32,
}

impl From<ExtraSwapFee> for Internal::ExtraFee {
    fn from(fee: ExtraSwapFee) -> Self {
        Internal::ExtraFee {
            id: fee.id,
            percentage: fee.percentage,
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct WebHook {
    pub url: String,
    pub statuses: Option<Vec<String>>,
}

impl<T> From<WebHook> for Internal::Webhook<T>
where
    T: FromStr,
{
    fn from(source: WebHook) -> Self {
        let statuses: Option<Vec<T>> = source
            .statuses
            .map(|list| list.iter().filter_map(|s| T::from_str(s).ok()).collect());
        Internal::Webhook {
            url: source.url,
            status: statuses,
            hash_swap_id: Some(false),
        }
    }
}

#[frb(opaque)]
pub struct MasterSwapKey {
    key: SwapMasterKey,
}

impl MasterSwapKey {
    // Derive swap master key mnemonics isolated from wallet mnemonic. This internally uses seed byte derivation using PBKDF2,
    // so cache the swap_mnemonics
    pub fn from_wallet_mnemonic(
        wallet_mnemonic: String,
        wallet_passphrase: Option<String>,
        network: Network,
    ) -> Result<Self, BoltzError> {
        let key = SwapMasterKey::new(
            &wallet_mnemonic,
            wallet_passphrase.as_deref(),
            network.into(),
        )?;
        Ok(MasterSwapKey { key })
    }

    pub fn from_mnemonic(
        mnemonic: String,
        passphrase: Option<String>,
        network: Network,
    ) -> Result<Self, BoltzError> {
        let key = SwapMasterKey::from_mnemonic(&mnemonic, passphrase.as_deref(), network.into())?;
        Ok(MasterSwapKey { key })
    }

    pub fn derive_btc_child_key(self, index: u64) -> Result<KeyPair, BoltzError> {
        let key_pair = self.key.derive_swapkey(index)?;
        Ok(key_pair.into())
    }

    pub fn derive_liquid_child_key(self, index: u64) -> Result<KeyPair, BoltzError> {
        let key_pair = self.key.derive_liquid_swapkey(index)?;
        Ok(key_pair.into())
    }

    #[frb(sync)]
    pub fn to_mnemonic_string(&self) -> String {
        self.key.mnemonic.to_string()
    }

    pub fn get_swap_xpub(&self) -> Result<String, BoltzError> {
        let seed = self.key.mnemonic.to_seed("");
        let root = Xpriv::new_master(bitcoin::Network::from(self.key.network), &seed)
            .map_err(|e| BoltzError::new("BIP32".to_string(), e.to_string()))?;
        let secp = Secp256k1::new();
        Ok(Xpub::from_priv(&secp, &root).to_string())
    }

    pub fn get_bolt12_signing_key(self, index: u32) -> Result<KeyPair, BoltzError> {
        let secp = Secp256k1::new();
        let child_path = DerivationPath::from_str(&format!("m/0'/{index}"))
            .map_err(|e| BoltzError::new("derivationPathPath".to_string(), e.to_string()))?;
        let signing_key = self
            .key
            .xprv
            .derive_priv(&secp, &child_path)
            .map_err(|e| BoltzError::new("derivingPath".to_string(), e.to_string()))?
            .to_keypair(&secp);
        Ok(signing_key.into())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkEndpoints {
    pub esplora: String,
    pub electrum: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupabaseConfig {
    pub project_ref: String,
    pub api_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkConfig {
    pub bitcoin: NetworkEndpoints,
    pub liquid: NetworkEndpoints,
    pub boltz_url: String,
    pub boltz_fee_cache_timeout_ms: u64,
    pub supabase: SupabaseConfig,
    pub server_url: String,
    pub server_api_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiConfig {
    pub mainnet: NetworkConfig,
    pub testnet: NetworkConfig,
    pub regtest: NetworkConfig,
}

impl ApiConfig {
    pub(crate) fn get_config(&self, network: &Network) -> &NetworkConfig {
        match network {
            Network::Mainnet => &self.mainnet,
            Network::Testnet => &self.testnet,
            Network::Regtest => &self.regtest,
        }
    }

    pub(crate) fn get_esplora_url(&self, network: &Network, chain: &Chain) -> String {
        let config = match network {
            Network::Mainnet => self.mainnet.clone(),
            Network::Testnet => self.testnet.clone(),
            Network::Regtest => self.regtest.clone(),
        };
        match chain {
            Chain::Bitcoin => config.bitcoin.esplora,
            Chain::Liquid => config.liquid.esplora,
        }
    }

    pub(crate) fn get_electrum_url(
        &self,
        network: &Network,
        chain: &Chain,
    ) -> Result<ElectrumUrl, BoltzError> {
        let config = match network {
            Network::Mainnet => self.mainnet.clone(),
            Network::Testnet => self.testnet.clone(),
            Network::Regtest => self.regtest.clone(),
        };
        ElectrumUrl::from_str(match chain {
            Chain::Bitcoin => &config.bitcoin.electrum,
            Chain::Liquid => &config.liquid.electrum,
        })
        .map_err(|e| BoltzError::new("Electrum".to_string(), e.to_string()))
    }

    pub(crate) fn get_boltz_client(&self, network: &Network) -> BoltzApiClientV2 {
        BoltzApiClientV2::new(
            ensure_http_prefix(&match network {
                Network::Mainnet => self.mainnet.boltz_url.clone(),
                Network::Testnet => self.testnet.boltz_url.clone(),
                Network::Regtest => self.regtest.boltz_url.clone(),
            }),
            Some(Duration::from_secs(15)),
        )
    }

    pub(crate) fn get_supabase_config(&self, network: &Network) -> SupabaseConfig {
        match network {
            Network::Mainnet => self.mainnet.supabase.clone(),
            Network::Testnet => self.testnet.supabase.clone(),
            Network::Regtest => self.regtest.supabase.clone(),
        }
    }

    #[frb(sync)]
    pub fn from_json(json: &str) -> Result<Self, BoltzError> {
        serde_json::from_str(json).map_err(|e| BoltzError::new("JSON".to_string(), e.to_string()))
    }

    #[frb(sync)]
    pub fn to_json(&self) -> Result<String, BoltzError> {
        serde_json::to_string(self)
            .map_err(|err| BoltzError::new("JSON".to_string(), err.to_string()))
    }
}

impl NetworkConfig {
    pub(crate) fn get_server_api_endpoint(&self, path: &str) -> String {
        format!(
            "https://api.{}/{}/{}",
            self.server_url, self.server_api_version, path
        )
    }
}

#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Swap {
    pub id: String,
    pub index: i64, // the negative space is used for swaps processed by server
    pub wallet_id: String,
    pub wallet_type: WalletType,
    pub network: Network,
    pub preimage: PreImage,

    // send amount and receive amount changes when chain quote is accepted.
    #[frb(non_final)]
    pub send_amount: u64,
    #[frb(non_final)]
    pub receive_amount: u64,
    pub creation_time: u128,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub completion_time: Option<u128>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub submarine: Option<SubmarineSwap>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reverse: Option<ReverseSwap>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chain: Option<ChainSwap>,

    #[frb(non_final)]
    pub swap_status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub failure_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub note: Option<String>,

    // changes when chain quote is accepted.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub boltz_fee: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lockup_fee: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claim_fee: Option<u64>,

    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    // address to which chain or submarine swap refunded to
    pub refunded_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[frb(non_final)]
    pub refund_fee: Option<u64>,

    #[frb(non_final)]
    pub transactions: Vec<SwapTransaction>,

    #[frb(non_final)]
    pub is_exchange_swap: bool,
    // This is set for exchange swap when the exchange order is created,
    // so that automatic settlement only completes if the lockup amount by exchange is close to this expected amount,
    // else let user handle the case
    #[frb(non_final)]
    pub expected_lockup_amount: Option<u64>,
}

impl Swap {
    #[frb(sync)]
    pub fn to_json(&self) -> Result<String, BoltzError> {
        serde_json::to_string(self)
            .map_err(|err| BoltzError::new("JSON".to_string(), err.to_string()))
    }

    #[frb(sync)]
    pub fn from_json(json: &str) -> Result<Self, BoltzError> {
        serde_json::from_str(json).map_err(|e| BoltzError::new("JSON".to_string(), e.to_string()))
    }
}

#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SubmarineSwap {
    pub from: Chain,
    pub keys: KeyPair,
    pub invoice: String,
    pub swap_create_res: SubmarineResponse,
}

#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReverseSwap {
    pub to: Chain,
    pub keys: KeyPair,
    pub swap_create_res: ReverseResponse,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ChainSwap {
    pub direction: ChainSwapDirection,
    pub claim_keys: KeyPair,
    pub refund_keys: KeyPair,
    pub lockup_details: ChainSwapData,
    pub claim_details: ChainSwapData,
}
