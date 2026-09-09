use crate::boltz::error::BoltzError;
use crate::boltz::types::PreImage;
use crate::lwk::wallet::Wallet;
use aes_gcm::aead::Payload;
use aes_gcm::{
    AeadCore, Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, rand_core::RngCore},
    aes::cipher::InvalidLength,
};
use aes_kw::Kek;
use bip32::{
    DerivationPath, ExtendedKey, Prefix, PublicKey, XPrv, XPub,
    secp256k1::sha2::{Digest, Sha256},
};
use bip39::rand::thread_rng;
use bip39::{Error as MnemonicError, Language, Mnemonic};
use boltz_client::bitcoin::hashes::{Hash, hash160};
use boltz_client::bitcoin::secp256k1::{Message, SecretKey};
use boltz_client::elements::AddressParams;
use boltz_client::swaps::magic_routing::sign_address;
use boltz_client::util::secrets::{Preimage, SwapMasterKey};
use boltz_client::{Keypair, Secp256k1, ToHex};
use flutter_rust_bridge::frb;
use fs2::FileExt;
use hkdf::Hkdf;
use lightning::bitcoin::base64::DecodeError;
use lightning::util::ser::Writeable;
use lwk_common::{FileStore, Store};
use lwk_wollet::elements::Address as LwkAddress;
use serde::{Deserialize, Serialize};
use std::fs;
use std::fs::File;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
pub enum Network {
    Mainnet,
    Testnet,
    Regtest,
}

#[derive(Debug)]
pub struct MannaError {
    pub kind: Option<String>,
    pub msg: String,
}

impl MannaError {
    pub fn new(message: String) -> Self {
        MannaError {
            kind: None,
            msg: message,
        }
    }

    pub fn from(kind: String, message: String) -> Self {
        MannaError {
            kind: Some(kind),
            msg: message,
        }
    }
}

impl From<MnemonicError> for MannaError {
    fn from(value: MnemonicError) -> Self {
        MannaError {
            kind: Some("Bip39".to_string()),
            msg: value.to_string(),
        }
    }
}
impl From<bip32::Error> for MannaError {
    fn from(value: bip32::Error) -> Self {
        MannaError {
            kind: Some("Bip32".to_string()),
            msg: value.to_string(),
        }
    }
}
impl From<lwk_wollet::Error> for MannaError {
    fn from(value: lwk_wollet::Error) -> Self {
        MannaError {
            kind: Some("LWK".to_string()),
            msg: value.to_string(),
        }
    }
}

#[frb(ignore)]
/// provides tokio runtime for api calls that doesn't require tokio to be initialized globally.
pub fn get_minimal_runtime() -> &'static tokio::runtime::Runtime {
    static MINIMAL_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    MINIMAL_RT.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("failed to create minimal tokio current-thread runtime")
    })
}

/// function to validate btc address according to network
pub fn validate_btc_address(address: &str, network: Network) -> Result<bool, MannaError> {
    let address = boltz_client::bitcoin::address::Address::from_str(address)
        .map_err(|_| MannaError::new("Failed to parse bitcoin address".to_string()))?;
    Ok(address.is_valid_for_network(match network {
        Network::Mainnet => boltz_client::bitcoin::Network::Bitcoin,
        Network::Testnet => boltz_client::bitcoin::Network::Testnet,
        Network::Regtest => boltz_client::bitcoin::Network::Regtest,
    }))
}

pub(crate) fn ensure_http_prefix(url: &str) -> String {
    let protocols = ["http://", "https://"];
    for protocol in protocols.iter() {
        if url.starts_with(protocol) {
            return url.to_string();
        }
    }
    format!("https://{url}")
}

/// get current time in milliseconds since epoch
pub(crate) fn get_current_time() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("time should go forward")
        .as_millis()
}

pub struct Mnemonics {
    pub sentence: String,
    pub entropy: Vec<u8>,
    pub seed_bytes: [u8; 64],
}

impl Mnemonics {
    // Generate mnemonics from internal rng. (default: 12 words)
    pub fn generate(word_count: Option<usize>) -> Result<Mnemonics, MannaError> {
        let mnemonic = Mnemonic::generate_in(Language::English, word_count.unwrap_or(12))?;

        Ok(Mnemonics {
            sentence: mnemonic.to_string(),
            entropy: mnemonic.to_entropy(),
            seed_bytes: mnemonic.to_seed(""),
        })
    }

    pub fn new(mnemonic: String, password: Option<String>) -> Result<Self, MannaError> {
        let mnemonic = Mnemonic::parse_in(Language::English, mnemonic)?;
        Ok(Mnemonics {
            sentence: mnemonic.to_string(),
            entropy: mnemonic.to_entropy(),
            seed_bytes: mnemonic.to_seed(password.unwrap_or("".to_string())),
        })
    }
}

#[frb(opaque)]
pub(super) struct BIP32 {
    xprv: Option<XPrv>,
    xpub: XPub,
}

impl BIP32 {
    pub fn from_mnemonics(mnemonic: String, password: Option<String>) -> Result<Self, MannaError> {
        Self::from_seed(Mnemonics::new(mnemonic, password)?.seed_bytes)
    }

    pub fn from_seed(seed: [u8; 64]) -> Result<Self, MannaError> {
        let xprv = XPrv::new(seed)?;
        let xpub = xprv.public_key();
        Ok(BIP32 {
            xprv: Some(xprv),
            xpub,
        })
    }

    pub fn from_xpub(xpub_str: String) -> Result<Self, MannaError> {
        let xpub = xpub_str
            .parse::<ExtendedKey>()
            .map_err(|_| MannaError::new("Invalid xpub string".to_string()))?
            .try_into()
            .map_err(|_| MannaError::new("Failed to parse xpub string".to_string()))?;
        Ok(BIP32 { xprv: None, xpub })
    }

    #[frb(sync)]
    pub fn derive_path(&self, path: String) -> Result<Self, MannaError> {
        let path: DerivationPath = DerivationPath::from_str(&path)?;

        // If we have xprv, derive using private key (supports hardened + normal)
        if let Some(xprv) = &self.xprv {
            let node = path.iter().fold(xprv.clone(), |current, child_num| {
                current.derive_child(child_num).unwrap_or(current)
            });
            let xpub = node.public_key();
            return Ok(BIP32 {
                xprv: Some(node),
                xpub,
            });
        }

        // xpub-only mode: only supports non-hardened derivation
        let node = path
            .iter()
            .try_fold(self.xpub.clone(), |current, child_num| {
                if child_num.is_hardened() {
                    Err(MannaError::new("Hardened child not supported".to_string()))
                } else {
                    current
                        .derive_child(child_num)
                        .map_err(|e| MannaError::new(e.to_string()))
                }
            })?;

        Ok(BIP32 {
            xprv: None,
            xpub: node,
        })
    }

    /// returns public key bytes
    #[frb(sync)]
    pub fn get_pub_key(&self) -> [u8; 33] {
        self.xpub.to_bytes()
    }

    /// returns pubkeyhash (pubkey->sha-256->RIPEMD-160)
    #[frb(sync)]
    pub fn get_pub_key_hash_hex(&self) -> String {
        hash160::Hash::hash(self.xpub.to_bytes().as_slice()).to_hex()
    }

    #[frb(sync)]
    pub fn get_private_key(&self) -> Option<[u8; 32]> {
        self.xprv.as_ref().map(|k| k.to_bytes())
    }

    #[frb(sync)]
    pub fn get_xpub(&self) -> String {
        self.xpub.to_extended_key(Prefix::XPUB).to_string()
    }

    #[frb(sync)]
    pub fn get_xprv(&self) -> Option<String> {
        self.xprv
            .as_ref()
            .map(|k| k.to_extended_key(Prefix::XPRV).to_string())
    }

    #[frb(sync)]
    pub fn is_watch_only(&self) -> bool {
        self.xprv.is_none()
    }

    #[frb(sync)]
    pub fn get_key_pair(&self) -> Option<KeyPair> {
        self.xprv.as_ref().map(|k| KeyPair {
            secret_key: k.to_bytes().to_vec(),
            public_key: self.xpub.to_bytes().to_vec(),
        })
    }
}

pub struct AddressEntry {
    pub index: u64,
    pub address: String,
    pub signature: String,
}

pub struct LnurlPoolEntry {
    pub index: u64,
    pub address: Option<AddressEntry>,
    pub preimage: PreImage,
    pub claim_key: KeyPair,
}

// this is used by all modules so its here and not in boltz/types
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyPair {
    pub secret_key: Vec<u8>,
    pub public_key: Vec<u8>,
}

impl KeyPair {
    #[frb(sync)]
    pub fn from_private_key(private_key: [u8; 32]) -> Result<Self, BoltzError> {
        let secp = Secp256k1::new();
        let secret_key = SecretKey::from_slice(&private_key)
            .map_err(|e| BoltzError::new("Key".to_string(), e.to_string()))?;
        Ok(Keypair::from_secret_key(&secp, &secret_key).into())
    }
}

impl TryInto<Keypair> for KeyPair {
    type Error = BoltzError;

    fn try_into(self) -> Result<Keypair, Self::Error> {
        let secp = Secp256k1::new();
        Keypair::from_seckey_slice(&secp, &self.secret_key)
            .map_err(|e| BoltzError::new("Key".to_string(), e.to_string()))
    }
}

impl From<Keypair> for KeyPair {
    fn from(value: Keypair) -> Self {
        KeyPair {
            secret_key: value.secret_bytes().to_vec(),
            public_key: value.public_key().encode(),
        }
    }
}

impl From<DecodeError> for MannaError {
    fn from(value: DecodeError) -> Self {
        MannaError {
            kind: Some("base64".to_string()),
            msg: value.to_string(),
        }
    }
}
impl From<aes_kw::Error> for MannaError {
    fn from(value: aes_kw::Error) -> Self {
        MannaError {
            kind: Some("AES-KW".to_string()),
            msg: value.to_string(),
        }
    }
}
impl From<InvalidLength> for MannaError {
    fn from(value: InvalidLength) -> Self {
        MannaError {
            kind: Some("Key".to_string()),
            msg: value.to_string(),
        }
    }
}
impl From<aes_gcm::Error> for MannaError {
    fn from(value: aes_gcm::Error) -> Self {
        MannaError {
            kind: Some("AES-GCM".to_string()),
            msg: value.to_string(),
        }
    }
}

pub struct Crypto {}

impl Crypto {
    /// util function that validates if given liquid address belongs to xpub for given network
    pub fn validate_liquid_address(
        xpub: String,
        address: String,
        index: u32,
        network: Network,
    ) -> Result<bool, MannaError> {
        let liquid_address =
            LwkAddress::from_str(&address).map_err(|e| MannaError::new(e.to_string()))?;

        let is_valid_network = match network {
            Network::Mainnet => liquid_address.params == &AddressParams::LIQUID,
            Network::Testnet => liquid_address.params == &AddressParams::LIQUID_TESTNET,
            Network::Regtest => liquid_address.params == &AddressParams::ELEMENTS,
        };

        if !is_valid_network {
            return Ok(false);
        }

        let target_program_hex = match liquid_address.payload {
            lwk_wollet::elements::address::Payload::WitnessProgram { program, .. } => program,
            _ => return Ok(false),
        };

        let xpub = XPub::from_str(xpub.as_str()).map_err(|e| MannaError::new(e.to_string()))?;
        let path: DerivationPath = DerivationPath::from_str(format!("m/0/{index}").as_str())?;
        let derived = path.iter().fold(xpub, |current, child_num| {
            let state = current.derive_child(child_num).ok();
            if let Some(state) = state {
                state
            } else {
                current
            }
        });
        let computed_hash = hash160::Hash::hash(derived.public_key().to_bytes().as_slice());

        Ok(computed_hash.as_byte_array() == target_program_hex.as_slice())
    }

    pub(crate) fn vec_to_array<T, const N: usize>(v: Vec<T>) -> Result<[T; N], MannaError> {
        v.try_into().map_err(|v: Vec<T>| {
            MannaError::new(format!(
                "Expected a Vec of length {} but it was {}",
                N,
                v.len()
            ))
        })
    }

    pub fn derive_hkdf(seed: &[u8], info: String) -> Result<[u8; 32], MannaError> {
        let hk = Hkdf::<sha2::Sha256>::new(Some(b"manna"), seed);
        let mut okm = [0u8; 32];
        hk.expand(info.as_bytes(), &mut okm)
            .map_err(|e| MannaError::from("HKDF".to_string(), e.to_string()))?;
        Ok(okm)
    }

    pub fn generate_x25519_key_pair(private_key_bytes: [u8; 32]) -> KeyPair {
        let x_sk = StaticSecret::from(private_key_bytes);
        let x_pk = XPublicKey::from(&x_sk);
        KeyPair {
            secret_key: x_sk.to_bytes().to_vec(),
            public_key: x_pk.to_bytes().to_vec(),
        }
    }

    pub fn derive_x25519_shared_secret(
        private_key_bytes: [u8; 32],
        public_key_bytes: [u8; 32],
    ) -> [u8; 32] {
        let shared_secret = StaticSecret::from(private_key_bytes)
            .diffie_hellman(&XPublicKey::from(public_key_bytes));
        shared_secret.to_bytes()
    }

    pub fn get_swap_encryption_key(swap_mnemonic: String) -> Result<Option<KeyPair>, MannaError> {
        Ok(BIP32::from_mnemonics(swap_mnemonic, None)?
            .derive_path("m/8888'/0'".to_string())?
            .get_key_pair())
    }

    pub fn generate_lnurl_pool(
        swap_mnemonics: &str,
        network: Network,
        indices: Vec<u64>,
        addresses: Option<Vec<(u64, String)>>,
    ) -> Result<Vec<LnurlPoolEntry>, MannaError> {
        let swap_master_key = SwapMasterKey::from_mnemonic(swap_mnemonics, None, network.into())
            .map_err(|e| MannaError::new(e.to_string()))?;

        if addresses.as_ref().is_some_and(|a| a.len() != indices.len()) {
            return Err(MannaError::new(
                "Addresses length must match indices".to_string(),
            ));
        }

        let build_entry = |lnurl_index: u64,
                           addr_opt: Option<(u64, String)>|
         -> Result<LnurlPoolEntry, MannaError> {
            let claim_keypair = swap_master_key
                .derive_liquid_swapkey(lnurl_index)
                .map_err(|e| MannaError::new(e.to_string()))?;

            let address_entry = if let Some((addr_idx, addr)) = addr_opt {
                let sig = sign_address(&addr, &claim_keypair)
                    .map_err(|e| MannaError::new(e.to_string()))?;

                Some(AddressEntry {
                    index: addr_idx,
                    address: addr,
                    signature: sig.to_string(),
                })
            } else {
                None
            };

            Ok(LnurlPoolEntry {
                index: lnurl_index,
                address: address_entry,
                preimage: Preimage::from_swap_key(&claim_keypair).into(),
                claim_key: claim_keypair.into(),
            })
        };

        if let Some(addrs) = addresses {
            indices
                .into_iter()
                .zip(addrs)
                .map(|(idx, addr_tuple)| build_entry(idx, Some(addr_tuple)))
                .collect()
        } else {
            indices
                .into_iter()
                .map(|idx| build_entry(idx, None))
                .collect()
        }
    }

    pub fn encrypt_chat_message(
        sender_priv_key: Vec<u8>,
        receiver_pub_key: Vec<u8>,
        message: String,
    ) -> Result<Vec<u8>, MannaError> {
        let sender_priv_bytes: [u8; 32] = Self::vec_to_array(sender_priv_key)?;
        let receiver_pub_bytes: [u8; 32] = Self::vec_to_array(receiver_pub_key)?;

        let sender_priv = StaticSecret::from(sender_priv_bytes);
        let receiver_pub = XPublicKey::from(receiver_pub_bytes);

        // Random Data encryption key
        let mut dek = [0u8; 32];
        thread_rng().fill_bytes(&mut dek);

        // Encrypt message with DEK
        let cipher = Aes256Gcm::new_from_slice(&dek)?;
        let message_nonce = Aes256Gcm::generate_nonce(&mut thread_rng());
        let ciphertext = cipher.encrypt(&message_nonce, message.as_ref())?;

        // Encrypt DEK for Receiver using AES-GCM
        let shared_receiver = sender_priv.diffie_hellman(&receiver_pub);
        let receiver_key =
            Self::derive_hkdf(shared_receiver.as_bytes(), "dek-wrap-receiver".to_string())?;
        let wrapped_receiver_dek = Kek::from(receiver_key).wrap_vec(&dek)?;

        let sender_key = Self::derive_hkdf(&sender_priv.to_bytes(), "dek-wrap-self".to_string())?;
        let wrapped_sender_dek = Kek::from(sender_key).wrap_vec(&dek)?;

        let mut payload = Vec::with_capacity(92 + ciphertext.len());
        payload.extend_from_slice(&message_nonce); // 12 bytes
        payload.extend_from_slice(&wrapped_receiver_dek); // 40 bytes
        payload.extend_from_slice(&wrapped_sender_dek); // 40 bytes
        payload.extend_from_slice(&ciphertext); // variable

        Ok(payload)
    }

    pub fn decrypt_chat_message_as_receiver(
        receiver_priv_key: Vec<u8>,
        sender_pub_key: Vec<u8>,
        payload: Vec<u8>,
    ) -> Result<String, MannaError> {
        if payload.len() < 108 {
            return Err(MannaError::new("Payload too short".to_string()));
        }

        let receiver_priv_bytes: [u8; 32] = Self::vec_to_array(receiver_priv_key)?;
        let sender_pub_bytes: [u8; 32] = Self::vec_to_array(sender_pub_key)?;

        let receiver_priv = StaticSecret::from(receiver_priv_bytes);
        let sender_pub = XPublicKey::from(sender_pub_bytes);

        // Extract payload parts
        let message_nonce_slice = &payload[0..12];
        let message_nonce = Nonce::from_slice(message_nonce_slice);
        let wrapped_dek_receiver = &payload[12..52];
        let ciphertext = &payload[92..];

        // Unwrap DEK for Receiver using AES-KW
        let shared_secret = receiver_priv.diffie_hellman(&sender_pub);
        let receiver_key =
            Self::derive_hkdf(shared_secret.as_bytes(), "dek-wrap-receiver".to_string())?;
        let dek = Kek::from(receiver_key).unwrap_vec(wrapped_dek_receiver)?;
        let dek_array: [u8; 32] = Self::vec_to_array(dek)?;

        // Decrypt message with DEK
        let plaintext =
            Aes256Gcm::new_from_slice(&dek_array)?.decrypt(message_nonce, ciphertext)?;

        String::from_utf8(plaintext).map_err(|e| MannaError::new(e.to_string()))
    }

    pub fn decrypt_chat_message_as_sender(
        sender_priv_key: Vec<u8>,
        payload: Vec<u8>,
    ) -> Result<String, MannaError> {
        if payload.len() < 108 {
            return Err(MannaError::new("Payload too short".to_string()));
        }

        let sender_priv_bytes: [u8; 32] = Self::vec_to_array(sender_priv_key)?;

        // Extract payload parts
        let message_nonce_slice = &payload[0..12];
        let message_nonce = Nonce::from_slice(message_nonce_slice);
        let wrapped_dek_sender = &payload[52..92];
        let ciphertext = &payload[92..];

        // Unwrap DEK for Sender using AES-KW
        let sender_priv = StaticSecret::from(sender_priv_bytes);
        let sender_key = Self::derive_hkdf(&sender_priv.to_bytes(), "dek-wrap-self".to_string())?;
        let dek = Kek::from(sender_key).unwrap_vec(wrapped_dek_sender)?;
        let dek_array: [u8; 32] = Self::vec_to_array(dek)?;

        // Decrypt message with DEK
        let plaintext =
            Aes256Gcm::new_from_slice(&dek_array)?.decrypt(message_nonce, ciphertext)?;

        String::from_utf8(plaintext).map_err(|e| MannaError::new(e.to_string()))
    }

    pub fn encrypt_ecies(pub_key: Vec<u8>, payload: Vec<u8>) -> Result<Vec<u8>, MannaError> {
        ecies::encrypt(pub_key.as_ref(), payload.as_ref())
            .map_err(|e| MannaError::new(e.to_string()))
    }

    pub fn decrypt_ecies(priv_key: Vec<u8>, payload: Vec<u8>) -> Result<Vec<u8>, MannaError> {
        ecies::decrypt(priv_key.as_ref(), payload.as_ref())
            .map_err(|e| MannaError::new(e.to_string()))
    }

    /// returns nonce (12 bytes) + cipher + mac (16 bytes)
    pub fn aes_encrypt(
        key: [u8; 32],
        plaintext: Vec<u8>,
        aad: Option<String>,
    ) -> Result<Vec<u8>, MannaError> {
        let nonce = Aes256Gcm::generate_nonce(&mut thread_rng());
        let payload = match aad {
            Some(ref a) => Payload {
                msg: plaintext.as_ref(),
                aad: a.as_ref(),
            },
            None => Payload::from(plaintext.as_ref()),
        };
        let cipher_text = Aes256Gcm::new_from_slice(&key)?.encrypt(&nonce, payload)?;
        let mut output = nonce.to_vec();
        output.extend_from_slice(&cipher_text);
        Ok(output)
    }

    /// pass nonce (12 bytes) + cipher + mac (16 bytes)
    pub fn aes_decrypt(
        key: [u8; 32],
        payload: Vec<u8>,
        aad: Option<String>,
    ) -> Result<Vec<u8>, MannaError> {
        if payload.len() < 28 {
            return Err(MannaError::new("Payload too short".to_string()));
        }
        let nonce = Nonce::from_slice(&payload[0..12]);
        let ciphertext = &payload[12..];

        let payload = match aad {
            Some(ref a) => Payload {
                msg: ciphertext.as_ref(),
                aad: a.as_ref(),
            },
            None => Payload::from(ciphertext.as_ref()),
        };
        Ok(Aes256Gcm::new_from_slice(&key)?.decrypt(nonce, payload)?)
    }

    pub fn secp256k1_sign(
        priv_key: Vec<u8>,
        message: Vec<u8>,
        return_der: bool,
        pre_hash: Option<bool>,
    ) -> Result<Vec<u8>, MannaError> {
        let m = if Some(true) == pre_hash {
            Sha256::digest(message).to_vec()
        } else {
            message
        };
        let message = Message::from_digest_slice(&m).map_err(|e| MannaError::new(e.to_string()))?;
        let signature = SecretKey::from_slice(priv_key.as_slice())
            .map_err(|e| MannaError::new(e.to_string()))?
            .sign_ecdsa(message);

        if return_der {
            Ok(signature.serialize_der().to_vec())
        } else {
            Ok(signature.serialize_compact().to_vec())
        }
    }
}

#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum WalletType {
    Full,
    WatchOnly,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidWallet {
    pub uuid: String,
    pub wallet_type: WalletType,
    pub descriptor: String,
    pub swap_mnemonic: String,

    pub upsert_derivation_private_key_hex: Option<String>, // used to sign the payload to upsert wallet data
    pub wallet_name: Option<String>,
}

impl LiquidWallet {
    pub(super) fn init(&self, lwk_path: String, network: Network) -> Result<Wallet, MannaError> {
        Wallet::init(network, lwk_path, self.descriptor.clone())
            .map_err(|e| MannaError::from("LWK".to_string(), e.msg))
    }
}

#[derive(Debug)]
#[frb(ignore)]
pub(crate) struct LockedFileStore {
    inner: FileStore,
    lock_file_path: PathBuf,
    local_mutex: Mutex<()>, // Mutex to protect concurrent access inside the same process
}

impl LockedFileStore {
    pub fn new(path: PathBuf) -> Result<Self, std::io::Error> {
        if !path.exists() {
            fs::create_dir_all(&path)?;
        }

        let lock_file_path = path.join("mutex.lock");
        let inner = FileStore::new(path)?;

        Ok(Self {
            inner,
            lock_file_path,
            local_mutex: Mutex::new(()),
        })
    }

    /// Internal helper to acquire an OS lock, execute a closure, and release it.
    fn with_lock<T, F>(&self, f: F) -> Result<T, std::io::Error>
    where
        F: FnOnce() -> Result<T, std::io::Error>,
    {
        // Thread safety
        let _local_guard = self
            .local_mutex
            .lock()
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::Other, "Local mutex poisoned"))?;

        // Multi-process safety
        let file = File::create(&self.lock_file_path)?;
        file.lock_exclusive()?;
        let result = f();

        let _ = file.unlock();
        result
    }
}

impl Store for LockedFileStore {
    type Error = std::io::Error;

    fn get<K: AsRef<[u8]>>(&self, key: K) -> Result<Option<Vec<u8>>, Self::Error> {
        self.with_lock(|| self.inner.get(key))
    }

    fn put<K: AsRef<[u8]>, V: AsRef<[u8]>>(&self, key: K, value: V) -> Result<(), Self::Error> {
        self.with_lock(|| self.inner.put(key, value))
    }

    fn remove<K: AsRef<[u8]>>(&self, key: K) -> Result<(), Self::Error> {
        self.with_lock(|| self.inner.remove(key))
    }

    fn is_persisted(&self) -> bool {
        true
    }
}
