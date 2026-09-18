use super::error::LwkError;
use crate::types::Network;
use flutter_rust_bridge::frb;
use lwk_wollet::{
    bitcoincore_rpc::jsonrpc::serde_json, elements::{
        hex::{FromHex, ToHex}, Address as LwkAddress, AddressParams,
        Script,
    }, secp256k1, AddressResult,
    Network as ElementsNetwork,
    WalletTx,
    WalletTxOut,
};
use serde::{Deserialize, Serialize};
use std::str::FromStr;

impl From<Network> for ElementsNetwork {
    fn from(value: Network) -> Self {
        match value {
            Network::Mainnet => ElementsNetwork::Liquid,
            Network::Testnet => ElementsNetwork::TestnetLiquid,
            Network::Regtest => ElementsNetwork::default_regtest(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Balance {
    pub asset_id: String,
    pub value: i64,
}

/// A multi asset wallet will have more than one item in the list for each asset
pub type Balances = Vec<Balance>;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]

pub struct Fee {
    pub asset_id: String,
    pub value: u64,
}
pub type Fees = Vec<Fee>;

impl From<WalletTxOut> for TxOut {
    fn from(wallet_tx_out: WalletTxOut) -> Self {
        TxOut {
            script_pubkey: wallet_tx_out.script_pubkey.to_hex(),
            height: wallet_tx_out.height,
            unblinded: TxOutSecrets {
                value: wallet_tx_out.unblinded.value,
                value_bf: wallet_tx_out.unblinded.value_bf.to_string(),
                asset: wallet_tx_out.unblinded.asset.to_string(),
                asset_bf: wallet_tx_out.unblinded.asset_bf.to_string(),
            },
            outpoint: OutPoint {
                txid: wallet_tx_out.outpoint.txid.to_string(),
                vout: wallet_tx_out.outpoint.vout,
            },
            address: Address::from(wallet_tx_out.address.clone()),
            is_spent: wallet_tx_out.is_spent,
        }
    }
}

/// Address class which contains both standard and confidential addresses with the address index in the wallet
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Address {
    pub standard: String,
    pub confidential: String,
    pub index: Option<u32>,
    pub blinding_key: Option<String>,
}

impl From<AddressResult> for Address {
    fn from(address: AddressResult) -> Self {
        Address {
            standard: address.address().to_unconfidential().to_string(),
            confidential: address.address().to_string(),
            index: Some(address.index()),
            blinding_key: address.address().blinding_pubkey.map(|pk| pk.to_string()),
        }
    }
}
impl From<LwkAddress> for Address {
    fn from(address: LwkAddress) -> Self {
        Address {
            standard: address.to_unconfidential().to_string(),
            confidential: address.to_string(),
            index: None,
            blinding_key: address.blinding_pubkey.map(|pk| pk.to_string()),
        }
    }
}

impl Address {
    /// Validate the address string and return the network
    pub fn validate(address_string: String) -> Result<Network, LwkError> {
        let address = LwkAddress::from_str(&address_string).map_err(LwkError::from)?;
        if *address.params == AddressParams::LIQUID {
            Ok(Network::Mainnet)
        } else if *address.params == AddressParams::LIQUID_TESTNET {
            Ok(Network::Testnet)
        } else {
            Ok(Network::Regtest)
        }
    }

    /// Create an address from a scriptpubkey. Always returns 0 as the index is only for wallet generated addresses
    pub fn address_from_script(
        network: Network,
        script: String,
        blinding_key: Option<String>,
    ) -> Result<Address, LwkError> {
        let blinding_pubkey = if blinding_key.is_none() {
            None
        } else {
            let pubkey = match secp256k1::PublicKey::from_str(&blinding_key.clone().unwrap()) {
                Ok(result) => result,
                Err(e) => return Err(LwkError { msg: e.to_string() }),
            };
            Some(pubkey)
        };
        let script_pubkey = match Script::from_hex(&script) {
            Ok(result) => result,
            Err(e) => return Err(LwkError { msg: e.to_string() }),
        };

        let address = LwkAddress::from_script(
            &script_pubkey,
            blinding_pubkey,
            match network {
                Network::Mainnet => &AddressParams::LIQUID,
                Network::Testnet => &AddressParams::LIQUID_TESTNET,
                Network::Regtest => &AddressParams::ELEMENTS,
            },
        );
        if let Some(address) = address {
            Ok(Address {
                standard: address.clone().to_unconfidential().to_string(),
                confidential: address.to_string(),
                index: None,
                blinding_key,
            })
        } else {
            Err(LwkError {
                msg: "Could not convert script to address".to_string(),
            })
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OutPoint {
    pub txid: String,
    pub vout: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TxOut {
    pub script_pubkey: String,
    pub outpoint: OutPoint,
    pub height: Option<u32>,
    pub unblinded: TxOutSecrets,
    pub is_spent: bool,
    pub address: Address,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TxOutSecrets {
    pub value: u64,
    pub value_bf: String,
    pub asset: String,
    pub asset_bf: String,
}

/// Transaction object returned by getTransactions.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Tx {
    pub timestamp: Option<u32>,
    pub kind: String,
    pub balances: Balances,
    pub txid: String,
    pub outputs: Vec<TxOut>,
    pub inputs: Vec<TxOut>,
    pub fee: u64,
    pub height: Option<u32>,
    pub unblinded_url: String,
    pub vsize: usize,
}

impl Tx {
    #[frb(sync)]
    pub fn to_json_string(&self) -> Result<String, LwkError> {
        match serde_json::to_string(self) {
            Ok(result) => Ok(result),
            Err(e) => Err(LwkError { msg: e.to_string() }),
        }
    }
    #[frb(sync)]
    pub fn from_json_string(json_str: &str) -> Result<Self, LwkError> {
        match serde_json::from_str(json_str) {
            Ok(result) => Ok(result),
            Err(e) => Err(LwkError { msg: e.to_string() }),
        }
    }
}

impl From<WalletTx> for Tx {
    fn from(wallet_tx: WalletTx) -> Self {
        let mut outputs: Vec<TxOut> = Vec::new();
        let mut inputs: Vec<TxOut> = Vec::new();

        for output in &wallet_tx.outputs {
            if output.is_some() {
                // safe to unwrap
                let script_pubkey = output.clone().unwrap().script_pubkey;
                outputs.push(TxOut {
                    script_pubkey: script_pubkey.to_hex(),
                    height: output.clone().unwrap().height,
                    unblinded: TxOutSecrets {
                        value: output.clone().unwrap().unblinded.value,
                        value_bf: output.clone().unwrap().unblinded.value_bf.to_string(),
                        asset: output.clone().unwrap().unblinded.asset.to_string(),
                        asset_bf: output.clone().unwrap().unblinded.asset_bf.to_string(),
                    },
                    outpoint: OutPoint {
                        txid: output.clone().unwrap().outpoint.txid.to_string(),
                        vout: output.clone().unwrap().outpoint.vout,
                    },
                    address: Address::from(output.clone().unwrap().address.clone()),
                    is_spent: output.clone().unwrap().is_spent,
                })
            }
        }

        for input in &wallet_tx.inputs {
            if input.is_some() {
                // safe to unwrap
                let script_pubkey = input.clone().unwrap().script_pubkey;
                inputs.push(TxOut {
                    script_pubkey: script_pubkey.to_string(),
                    height: input.clone().unwrap().height,
                    unblinded: TxOutSecrets {
                        value: input.clone().unwrap().unblinded.value,
                        value_bf: input.clone().unwrap().unblinded.value_bf.to_string(),
                        asset: input.clone().unwrap().unblinded.asset.to_string(),
                        asset_bf: input.clone().unwrap().unblinded.asset_bf.to_string(),
                    },
                    outpoint: OutPoint {
                        txid: input.clone().unwrap().outpoint.txid.to_string(),
                        vout: input.clone().unwrap().outpoint.vout,
                    },
                    address: Address::from(input.clone().unwrap().address.clone()),
                    is_spent: input.clone().unwrap().is_spent,
                })
            }
        }
        Tx {
            kind: wallet_tx.type_.clone(),
            balances: wallet_tx
                .balance
                .iter()
                .map(|(&asset_id, &value)| Balance {
                    asset_id: asset_id.to_string(),
                    value,
                })
                .collect(),
            txid: wallet_tx.tx.txid().to_string(),
            outputs,
            inputs,
            fee: wallet_tx.fee.clone(),
            timestamp: wallet_tx.timestamp.clone(),
            height: wallet_tx.height.clone(),
            unblinded_url: wallet_tx.unblinded_url(""),
            vsize: wallet_tx.tx.discount_vsize(),
        }
    }
}

/// Decoded PSET data
#[derive(Clone, Debug, PartialEq)]
pub struct DecodedPset {
    pub discounted_vsize: usize,
    pub discounted_weight: usize,
    pub fees: Fees,
    pub balances: Balances,
    pub input_address_derivations: Vec<String>,
}
