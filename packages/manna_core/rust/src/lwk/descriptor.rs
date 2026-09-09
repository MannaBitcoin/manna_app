use super::error::LwkError;
use crate::util::Network;
use lwk_signer::SwSigner;
use lwk_wollet::WolletDescriptor;
use lwk_wollet::elements_miniscript::descriptor::checksum::desc_checksum;
use lwk_wollet::elements_miniscript::{DescriptorPublicKey, ForEachKey};

pub struct Descriptor {}

impl Descriptor {
    /// Create new wpkh confidential descriptor based on Slip77 blinding key derivation
    pub fn new_confidential(network: Network, mnemonic: String) -> Result<String, LwkError> {
        let desc_str = lwk_common::singlesig_desc(
            &SwSigner::new(&mnemonic, network == Network::Mainnet)?,
            lwk_common::Singlesig::Wpkh,
            lwk_common::DescriptorBlindingKey::Slip77,
        )?;
        Ok(desc_str)
    }

    pub fn green_wallet_watch_only(descriptor: String) -> Result<String, LwkError> {
        const SEARCH_TERM: &str = "/<0;1>/*";
        if !descriptor.contains(SEARCH_TERM) {
            return Err(LwkError::from(
                "Warning: Descriptor does not contain the expected pattern '<0;1>/*'".to_string(),
            ));
        }

        let desc = descriptor[0..descriptor.len() - 9].to_string();
        let desc_0 = desc.replace(SEARCH_TERM, "/0/*");
        let checksum_0 = desc_checksum(&desc_0).map_err(|e| e.to_string())?;
        let desc_1 = desc.replace(SEARCH_TERM, "/1/*");
        let checksum_1 = desc_checksum(&desc_1).map_err(|e| e.to_string())?;

        Ok(format!("{desc_0}#{checksum_0}\n{desc_1}#{checksum_1}"))
    }

    /// parse multi-line as well as single line wallet descriptor and returns single line descriptor that can be used to initialize wallet.
    pub fn parse_descriptor(descriptor_str: &str) -> Result<String, LwkError> {
        Ok(WolletDescriptor::from_str_relaxed(&descriptor_str)
            .map_err(|e| LwkError::from(e))?
            .to_string())
    }

    /// extracts (xpub, derivationPath) from wallet descriptor string
    pub fn extract_xpub(descriptor_str: &str) -> Result<Option<(String, String)>, LwkError> {
        let descriptor =
            WolletDescriptor::from_str_relaxed(&descriptor_str).map_err(|e| LwkError::from(e))?;
        let mut xpub: Option<(String, String)> = None;
        descriptor.descriptor()?.for_each_key(|k| match k {
            DescriptorPublicKey::Single(_) => false,
            DescriptorPublicKey::XPub(k) => {
                if let Some(origin) = &k.origin {
                    xpub = Some((k.xkey.to_string(), origin.1.to_string()))
                }
                true
            }
            DescriptorPublicKey::MultiXPub(k) => {
                if let Some(origin) = &k.origin {
                    xpub = Some((k.xkey.to_string(), origin.1.to_string()))
                }
                true
            }
        });
        Ok(xpub)
    }
}
