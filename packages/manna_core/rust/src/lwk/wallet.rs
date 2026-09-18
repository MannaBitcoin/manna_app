use super::error::LwkError;
use super::types::{Address, Balance, Balances, DecodedPset, Fee, Tx};
use crate::types::Network;
use crate::util::LockedFileStore;
use flutter_rust_bridge::frb;
use lwk_common::Signer;
use lwk_signer::SwSigner;
use lwk_wollet::elements::hex::ToHex;
use lwk_wollet::elements::{pset::PartiallySignedTransaction, Address as LwkAddress};
use lwk_wollet::hashes::{sha256, Hash};
use lwk_wollet::{
    full_scan_with_electrum_client, AddressResult, ElectrumClient, Network as ElementsNetwork, Wollet,
    WolletBuilder, WolletDescriptor,
};
use std::convert::TryFrom;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::MutexGuard;
use std::sync::{Arc, Mutex};

/// Main wallet object
pub struct Wallet {
    inner: Mutex<Wollet>,
}

impl Wallet {
    /// Used internally to create a lock on the wallet while being used.
    fn get_wallet(&self) -> Result<MutexGuard<'_, Wollet>, LwkError> {
        {
            match self.inner.lock() {
                Ok(result) => Ok(result),
                Err(_) => Err(LwkError {
                    msg: "Could not aquire lock on wallet".to_string(),
                }),
            }
        }
    }

    /// Initializes a wallet from a specific db path and descriptor
    pub fn init(
        network: Network,
        dbpath: String,
        descriptor_str: String,
    ) -> Result<Wallet, LwkError> {
        let descriptor = WolletDescriptor::from_str(descriptor_str.as_str())?;
        let network: ElementsNetwork = network.into();

        let descriptor_hash_hex = sha256::Hash::hash(descriptor_str.as_bytes()).to_hex();
        let mut root_path = PathBuf::from(dbpath);
        root_path.push(network.as_str());
        root_path.push(descriptor_hash_hex);

        let locked_store =
            LockedFileStore::new(root_path.clone()).map_err(|e| LwkError::from(e.to_string()))?;
        // let file_store = FileStore::new(root_path.clone()).map_err(|e| LwkError::from(e.to_string()))?;

        let wollet = WolletBuilder::new(network, descriptor)
            .with_updates_store(Arc::new(locked_store))
            .set_encryption_updates_store(true)
            .build()?;

        let wallet = Wallet {
            inner: Mutex::new(wollet),
        };
        Ok(wallet)
    }

    /// Syncs the wallet db with its latest state fetched from the electrum server
    pub fn sync(&self, electrum_url: String) -> Result<(), LwkError> {
        let mut electrum_client: ElectrumClient = ElectrumClient::new(
            &lwk_wollet::ElectrumUrl::from_str(&electrum_url)
                .map_err(|e| LwkError { msg: e.to_string() })?,
        )?;

        let mut wallet = self.get_wallet()?;
        match full_scan_with_electrum_client(&mut wallet, &mut electrum_client) {
            Ok(_) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Get the descriptor string for the wallet
    pub fn descriptor(&self) -> Result<String, LwkError> {
        Ok(self.get_wallet()?.descriptor()?.to_string())
    }

    #[frb(sync)]
    /// Get network of the wallet
    pub fn network(&self) -> Result<Network, LwkError> {
        Ok(match self.get_wallet()?.network() {
            ElementsNetwork::Liquid => Network::Mainnet,
            ElementsNetwork::TestnetLiquid => Network::Testnet,
            ElementsNetwork::CustomElements { .. } => Network::Regtest,
        })
    }

    /// Get storage path of persister of wallet
    pub fn get_wallet_fs_path(network: Network, descriptor: String) -> Result<String, LwkError> {
        let network: ElementsNetwork = network.into();
        let descriptor_hash_hex = sha256::Hash::hash(descriptor.as_bytes()).to_hex();

        let mut root_path = PathBuf::new();
        root_path.push(network.as_str());
        root_path.push(descriptor_hash_hex);

        root_path
            .to_str()
            .ok_or(LwkError {
                msg: "Failed to get path".to_string(),
            })
            .map(|t| t.to_string())
    }

    /// Get the blinding key string for the wallet
    pub fn blinding_key(&self) -> Result<String, LwkError> {
        Ok(self.get_wallet()?.descriptor()?.key.to_string())
    }

    /// Get the last unused address from the wallet
    pub fn address_last_unused(&self) -> Result<Address, LwkError> {
        let address: AddressResult = self.get_wallet()?.address(None)?;
        Ok(address.into())
    }

    /// Get an address from a specific index
    pub fn address(&self, index: u32) -> Result<Address, LwkError> {
        let address: AddressResult = self.get_wallet()?.address(Some(index))?;
        Ok(address.into())
    }

    /// Get balances for a wallet.
    pub fn balances(&self) -> Result<Balances, LwkError> {
        let balances: Balances = self
            .get_wallet()?
            .balance()?
            .iter()
            .filter_map(|(&asset_id, &value)| match i64::try_from(value) {
                Ok(converted_value) => Some(Balance {
                    asset_id: asset_id.to_string(),
                    value: converted_value,
                }),
                Err(_) => {
                    eprintln!("Warning: Overflow encountered converting u64 to i64");
                    None
                }
            })
            .collect();
        Ok(balances)
    }

    /// Get the transaction history of the wallet
    pub fn txs(&self) -> Result<Vec<Tx>, LwkError> {
        let txs = self
            .get_wallet()?
            .transactions()?
            .iter()
            .map(|x| Tx::from(x.to_owned()))
            .collect();
        Ok(txs)
    }

    /// Build a LBTC transaction
    pub fn build_lbtc_tx(
        &self,
        recipients: Vec<(String, u64)>,
        fee_rate: f32,
        drain: bool,
    ) -> Result<String, LwkError> {
        let wallet = self.get_wallet()?;
        let tx_builder = wallet.tx_builder();

        if drain {
            // If drain mode is enabled, drain the wallet to the first recipient's address
            if recipients.len() != 1 {
                return Err(LwkError {
                    msg: "Draining wallet is only supported for single recipient".to_string(),
                });
            }

            let (out_address, _) = &recipients[0];
            let address = LwkAddress::from_str(out_address)?;
            let pset = tx_builder
                .drain_lbtc_wallet()
                .drain_lbtc_to(&address)?
                .enable_ct_discount()
                .fee_rate(Some(fee_rate))
                .finish()?;
            Ok(pset.to_string())
        } else {
            let mut tx_builder = tx_builder;
            for (out_address, sats) in recipients {
                let address = LwkAddress::from_str(&out_address)?;
                tx_builder = tx_builder.add_lbtc_recipient(&address, sats)?;
            }
            let pset = tx_builder
                .enable_ct_discount()
                .fee_rate(Some(fee_rate))
                .finish()?;
            Ok(pset.to_string())
        }
    }

    /// Decode a transaction given a PSET
    pub fn decode_tx(&self, pset_string: String) -> Result<DecodedPset, LwkError> {
        let pset = PartiallySignedTransaction::from_str(&pset_string)?;
        let tx = pset
            .extract_tx()
            .map_err(|_| LwkError::from("Invalid Pset".to_string()))?;

        let pset_details = self.get_wallet()?.get_details(&pset)?;
        let balances: Balances = pset_details
            .balances()
            .iter()
            .map(|(&asset_id, &value)| Balance {
                asset_id: asset_id.to_string(),
                value,
            })
            .collect();

        let mut input_derivation_paths: Vec<String> = Vec::new();
        for input in pset.inputs().iter() {
            if let Some((_pubkey, (_fingerprint, derivation_path))) =
                input.bip32_derivation.iter().next()
            {
                let path = derivation_path
                    .to_u32_vec()
                    .iter()
                    .map(|&index| {
                        if index >= 0x80000000 {
                            format!("{}'", index - 0x80000000)
                        } else {
                            index.to_string()
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("/");
                input_derivation_paths.push(path);
            }
        }

        Ok(DecodedPset {
            discounted_vsize: tx.discount_vsize(),
            discounted_weight: tx.discount_weight(),
            fees: pset_details
                .fees()
                .iter()
                .map(|(&asset_id, &value)| Fee {
                    asset_id: asset_id.to_string(),
                    value,
                })
                .collect(),
            balances,
            input_address_derivations: input_derivation_paths,
        })
    }

    /// Sign a wallet transaction, returns pset
    pub fn sign_tx(
        &self,
        network: Network,
        pset: String,
        mnemonic: String,
    ) -> Result<String, LwkError> {
        let is_mainnet = network == Network::Testnet;
        let signer: SwSigner = SwSigner::new(&mnemonic, is_mainnet)?;
        let mut pset = PartiallySignedTransaction::from_str(&pset)?;
        let _ = signer.sign(&mut pset);
        let tx = self.get_wallet()?.finalize(&mut pset)?;
        let finalized_pset = PartiallySignedTransaction::from_tx(tx.clone());
        Ok(finalized_pset.to_string())
    }
}
