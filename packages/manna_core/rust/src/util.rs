use crate::types::{DecodedBolt12Offer, DecodedInvoice, Network};
use aes_gcm::aead::Payload;
use aes_gcm::{
    aead::{rand_core::RngCore, Aead}, aes::cipher::InvalidLength, AeadCore, Aes256Gcm,
    KeyInit,
    Nonce,
};
use aes_kw::Kek;
use bip32::{
    secp256k1::sha2::{Digest, Sha256}, DerivationPath, ExtendedKey, Prefix, XPrv,
    XPub,
};
use bip353::{Bip353Resolver, PaymentType, ResolverConfig};
use bip39::{rand::thread_rng, Error as MnemonicError, Language, Mnemonic};
use bitcoin::bech32::{Bech32m, Hrp};
use bitcoin::secp256k1::PublicKey;
use bitcoin::{
    bech32,
    constants::ChainHash,
    hashes::{hash160, Hash},
    secp256k1::{Message, SecretKey},
};
use flutter_rust_bridge::frb;
use fs2::FileExt;
use hkdf::Hkdf;
use lightning::offers::{
    invoice::Bolt12Invoice,
    offer::{Amount, Offer},
};
use lightning::types::string::PrintableString;
use lightning_invoice::Bolt11Invoice;
use lwk_common::{FileStore, Store};
use lwk_wollet::elements::hex::ToHex;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    fs::File,
    path::PathBuf,
    str::FromStr,
    sync::{Mutex, OnceLock},
    time::Duration,
};
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret};

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

#[frb(unignore)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyPair {
    pub secret_key: Vec<u8>,
    pub public_key: Vec<u8>,
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
    const TAG: u8 = 0x0a; // (1 << 3) | 2

    fn encode_proto(key: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(2 + key.len());
        out.push(Self::TAG);
        // Compressed pubkeys are 33 bytes; fall back to error if ever larger.
        let key_len: u8 = key.len().try_into().expect("key length exceeds 255 bytes");
        out.push(key_len);
        out.extend_from_slice(key);
        out
    }

    fn decode_proto(buf: &[u8]) -> Result<&[u8], MannaError> {
        if buf.len() >= 3 && buf[0] == Self::TAG && buf[1] as usize + 2 == buf.len() {
            Ok(&buf[2..])
        } else {
            Err(MannaError::new("Invalid tag".to_string()))
        }
    }

    #[frb(sync)]
    /// Encodes spark identity pub key into spark address
    pub fn encode_spark_address(
        identity_pub_key_hex: String,
        network: Network,
    ) -> Result<String, MannaError> {
        let bytes =
            hex::decode(identity_pub_key_hex).map_err(|e| MannaError::new(e.to_string()))?;
        PublicKey::from_slice(&bytes)
            .map_err(|_| MannaError::new("InvalidSecp256k1".to_string()))?;

        if bytes.len() != 33 {
            return Err(MannaError::new(format!("WrongKeyLength {}", bytes.len())));
        }

        let hrp = Hrp::parse(match network {
            Network::Mainnet => "spark",
            Network::Testnet => "sparkt",
            Network::Regtest => "sparkrt",
        })
        .expect("static HRP is valid");
        let addr = bech32::encode::<Bech32m>(hrp, &Self::encode_proto(&bytes))
            .map_err(|e| MannaError::new(e.to_string()))?;

        Ok(addr)
    }

    #[frb(sync)]
    /// Decodes spark address into identity pub key
    pub fn decode_spark_address(addr: String) -> Result<(String, Network), MannaError> {
        if addr.len() > 90 {
            return Err(MannaError::new("InvalidLength".to_string()));
        }

        let has_upper = addr.bytes().any(|b| b.is_ascii_uppercase());
        let has_lower = addr.bytes().any(|b| b.is_ascii_lowercase());
        if has_upper && has_lower {
            return Err(MannaError::new("MixedCaseAddress".to_string()));
        }

        let (hrp, proto) = bech32::decode(&addr).map_err(|e| MannaError::new(e.to_string()))?;

        // The Bech32 spec requires the HRP to be lowercase. The `bech32`
        // crate accepts uppercase HRPs, so we enforce the stricter rule
        // here.
        let hrp_str = hrp.to_string();
        if hrp_str.bytes().any(|b| b.is_ascii_uppercase()) {
            return Err(MannaError::new("MixedCaseAddress".to_string()));
        }

        // Reject legacy Bech32 (BIP-173) by re-encoding with Bech32m and
        // comparing the checksum. If it differs, the original variant must
        // have been classic Bech32.
        let reencoded =
            bech32::encode::<Bech32m>(hrp, &proto).map_err(|e| MannaError::new(e.to_string()))?;
        if reencoded.to_lowercase() != addr.to_lowercase() {
            return Err(MannaError::new("Address is not Bech32m".to_string()));
        }

        let network = match hrp_str.as_str() {
            "spark" => Some(Network::Mainnet),
            "sparkt" => Some(Network::Testnet),
            "sparkrt" => Some(Network::Regtest),
            _ => None,
        }
        .ok_or_else(|| MannaError::new(format!("unknown HRP prefix: {}", hrp_str.clone())))?;

        let key = Self::decode_proto(&proto)?;

        if key.len() != 33 {
            return Err(MannaError::new(format!(
                "wrong pubkey length: {} (expected 33)",
                key.len()
            )));
        }

        let hex_key = hex::encode(key);
        PublicKey::from_slice(key).map_err(|_| MannaError::new("InvalidSecp256k1".to_string()))?;

        Ok((hex_key, network))
    }

    #[frb(sync)]
    /// parses bolt11 invoice, if you want to extract bip21 address used to create this lightning invoice use [Self::from_bolt11_invoice] instead.
    pub fn decode_bolt11_invoice(invoice: String) -> Result<DecodedInvoice, MannaError> {
        let inv = Bolt11Invoice::from_str(&invoice).map_err(|e| MannaError::new(e.to_string()))?;
        let millis_since_epoch = std::time::UNIX_EPOCH
            .elapsed()
            .map_err(|e| MannaError::new(e.to_string()))?;
        let network = match inv.network() {
            bitcoin::Network::Bitcoin => Network::Mainnet,
            bitcoin::Network::Testnet | bitcoin::Network::Testnet4 | bitcoin::Network::Signet => {
                Network::Testnet
            }
            bitcoin::Network::Regtest => Network::Regtest,
        };
        Ok(DecodedInvoice {
            expires_at: inv
                .expires_at()
                .unwrap_or(Duration::from_secs(0))
                .as_millis(),
            is_expired: millis_since_epoch >= inv.expires_at().unwrap_or(Duration::from_secs(0)),
            msats: inv.amount_milli_satoshis().unwrap_or(0),
            network,
            bip21: None,
            preimage_hash: inv.payment_hash().to_string(),
            description: Some(inv.description().to_string()),
            issuer: None,
        })
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

    /// function to fetch bolt12 lightning offer for a given username using DNS query according to BIP-353
    pub async fn fetch_bolt12_offer_uri_from_username(
        network: Network,
        username: String,
    ) -> Result<Option<String>, MannaError> {
        let resolver = Bip353Resolver::with_config(match network {
            Network::Mainnet => ResolverConfig::default(),
            Network::Testnet => ResolverConfig::testnet(),
            Network::Regtest => ResolverConfig::regtest(),
        })
        .map_err(|e| MannaError::from("BIP-353 resolver config".to_string(), e.to_string()))?;
        let offer = resolver
            .resolve_address(&username)
            .await
            .map_err(|e| MannaError::new(format!("BIP 353 resolution failed: {e}")))?;
        if offer.is_reusable && offer.payment_type == PaymentType::LightningOffer {
            return Ok(Some(offer.uri));
        }
        Ok(None)
    }

    /// helper function to parse bolt12 invoice
    #[frb(ignore)]
    pub fn parse_bolt12_invoice(invoice: String) -> Result<Bolt12Invoice, MannaError> {
        let p = bech32::primitives::decode::CheckedHrpstring::new::<bech32::NoChecksum>(&invoice)
            .map_err(|e| MannaError::from("Bolt12 invoice".to_string(), e.to_string()))?;
        if p.hrp().to_lowercase() != "lni" {
            return Err(MannaError::new(
                "invalid hrp for bolt12 invoice".to_string(),
            ));
        }
        let data = p.byte_iter().collect::<Vec<u8>>();
        let bolt12_invoice = Bolt12Invoice::try_from(data)
            .map_err(|e| MannaError::new(format!("Failed to parse BOLT12 invoice: {:?}", e)))?;

        Ok(bolt12_invoice)
    }

    #[frb(sync)]
    pub fn decode_bolt12_invoice(invoice: String) -> Result<DecodedInvoice, MannaError> {
        let inv = Self::parse_bolt12_invoice(invoice)?;
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
