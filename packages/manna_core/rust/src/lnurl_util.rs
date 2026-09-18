use crate::util::MannaError;
use flutter_rust_bridge::frb;
use lnurl::get_derivation_path;
use lnurl::lnurl::LnUrl;
use std::str::FromStr;
use url::Url;

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
}
