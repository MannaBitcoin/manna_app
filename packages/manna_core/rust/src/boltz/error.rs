use crate::util::MannaError;
use boltz_client::bitcoin::key::ParsePublicKeyError;
use boltz_client::error::Error;
use serde::{Deserialize, Serialize};
use std::fmt::{Display, Formatter};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct BoltzError {
    pub kind: String,
    pub message: String,
}

impl BoltzError {
    pub fn new(kind: String, message: String) -> Self {
        BoltzError { kind, message }
    }

    pub(crate) fn esplora_error(e: String) -> Self {
        BoltzError::new("Esplora".to_string(), e)
    }
}

impl Display for BoltzError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}-{}", self.kind, self.message)
    }
}

impl From<Error> for BoltzError {
    fn from(value: Error) -> Self {
        BoltzError {
            kind: value.name(),
            message: value.message(),
        }
    }
}

impl From<ParsePublicKeyError> for BoltzError {
    fn from(value: ParsePublicKeyError) -> Self {
        BoltzError {
            kind: "Pubkey".to_string(),
            message: value.to_string(),
        }
    }
}

impl From<MannaError> for BoltzError {
    fn from(value: MannaError) -> Self {
        BoltzError {
            kind: value.kind.unwrap_or("Manna Util".to_string()),
            message: value.msg,
        }
    }
}
