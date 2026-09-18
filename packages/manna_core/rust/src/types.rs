use crate::util::MannaError;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum Network {
    Mainnet,
    Testnet,
    Regtest,
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
#[frb(unignore)]
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

    pub(crate) fn get_supabase_config(&self, network: &Network) -> SupabaseConfig {
        match network {
            Network::Mainnet => self.mainnet.supabase.clone(),
            Network::Testnet => self.testnet.supabase.clone(),
            Network::Regtest => self.regtest.supabase.clone(),
        }
    }

    #[frb(sync)]
    pub fn from_json(json: &str) -> Result<Self, MannaError> {
        serde_json::from_str(json).map_err(|e| MannaError::new(e.to_string()))
    }

    #[frb(sync)]
    pub fn to_json(&self) -> Result<String, MannaError> {
        serde_json::to_string(self).map_err(|err| MannaError::new(err.to_string()))
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

#[frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum WalletType {
    Full,
}

#[frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidWallet {
    pub uuid: String,
    pub wallet_type: WalletType,

    pub upsert_derivation_private_key_hex: Option<String>, // used to sign the payload to upsert wallet data
    pub wallet_name: Option<String>,
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
