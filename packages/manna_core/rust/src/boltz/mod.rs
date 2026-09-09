use crate::boltz::types::ApiConfig;

pub mod bolt12;
pub mod error;
pub mod process_swap;
pub mod swap;
pub mod swap_transaction;
pub mod types;

#[derive(Debug)]
pub struct BoltzManager {
    pub api_config: ApiConfig,
}
