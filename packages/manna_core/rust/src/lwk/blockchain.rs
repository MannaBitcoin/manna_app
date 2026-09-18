use std::str::FromStr;

use super::error::LwkError;
use lwk_wollet::{
    blocking::BlockchainBackend,
    elements::{encode::deserialize, pset::PartiallySignedTransaction, Transaction},
    ElectrumClient,
};

pub struct Blockchain {}

impl Blockchain {
    /// Broadcast transaction bytes
    pub fn broadcast_tx_bytes(electrum_url: String, tx_bytes: Vec<u8>) -> Result<String, LwkError> {
        let electrum_url = lwk_wollet::ElectrumUrl::from_str(&electrum_url)
            .map_err(|e| LwkError { msg: e.to_string() })?;
        let electrum_client = ElectrumClient::new(&electrum_url)?;
        let tx: Transaction = deserialize(&tx_bytes)?;
        let txid = electrum_client.broadcast(&tx)?;
        Ok(txid.to_string())
    }

    /// Broadcast a signed pset
    pub fn broadcast_signed_pset(
        electrum_url: String,
        signed_pset: String,
    ) -> Result<String, LwkError> {
        let electrum_url = lwk_wollet::ElectrumUrl::from_str(&electrum_url)
            .map_err(|e| LwkError { msg: e.to_string() })?;
        let electrum_client = ElectrumClient::new(&electrum_url)?;
        let pset = PartiallySignedTransaction::from_str(&signed_pset)?;
        let tx = pset
            .extract_tx()
            .map_err(|_| LwkError::from("Invalid Pset".to_string()))?;
        let txid = electrum_client.broadcast(&tx)?;
        Ok(txid.to_string())
    }
}
