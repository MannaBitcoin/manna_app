use crate::boltz::error::BoltzError;
use crate::boltz::types::{decode_bolt12_offer, MasterSwapKey};
use crate::boltz::BoltzManager;
use crate::util::{KeyPair, LiquidWallet, MannaError, Network};
use bip353::{Bip353Resolver, PaymentType, ResolverConfig};
use bip39::rand::thread_rng;
use boltz_client::bitcoin::bech32::primitives::decode::CheckedHrpstring;
use boltz_client::bitcoin::bech32::{Hrp, NoChecksum};
use boltz_client::bitcoin::constants::ChainHash;
use boltz_client::bitcoin::hashes::{sha256, Hash};
use boltz_client::bitcoin::secp256k1::{Message, PublicKey};
use boltz_client::bitcoin::{
    bech32,
    key::rand::RngCore,
    Network::{Bitcoin, Regtest, Testnet},
};
use boltz_client::boltz::GetBolt12FetchRequest;
use boltz_client::{Keypair, Secp256k1, ToHex};
use flutter_rust_bridge::frb;
use lightning::bitcoin::hashes::{HashEngine, Hmac, HmacEngine};
use lightning::bitcoin::secp256k1::ecdh::SharedSecret;
use lightning::bitcoin::secp256k1::SecretKey;
use lightning::blinded_path::message::{MessageContext, OffersContext};
use lightning::blinded_path::payment::{
    BlindedPaymentPath, Bolt12OfferContext, PaymentConstraints, PaymentContext,
    UnauthenticatedReceiveTlvs,
};
use lightning::blinded_path::BlindedHop;
use lightning::bolt11_invoice::PaymentSecret;
use lightning::ln::inbound_payment::ExpandedKey;
use lightning::offers::invoice::{Bolt12Invoice, UnsignedBolt12Invoice};
use lightning::offers::invoice_request::{InvoiceRequest, InvoiceRequestFields};
use lightning::sign::EntropySource;
use lightning::types::payment::PaymentHash;
use lightning::types::string::UntrustedString;
use lightning::util::ser::Writeable;
use lightning::{
    blinded_path::message::BlindedMessagePath,
    offers::{
        nonce::Nonce,
        offer::{Offer, OfferBuilder},
    },
    sign::{RandomBytes, ReceiveAuthKey},
};
use tracing::instrument;

#[derive(Debug)]
pub struct Bolt12OfferCreationParam {
    pub liquid_wallet: LiquidWallet,
    pub issuer_name: Option<String>,
    pub description: Option<String>,
}

pub struct DecodedBolt12InvoiceRequest {
    pub payer_signing_key: String,
    pub network: Network,
    pub amount_msats: Option<u64>,
    pub quantity: Option<u64>,
    pub payer_note: Option<String>,
}

impl DecodedBolt12InvoiceRequest {
    #[frb(sync)]
    pub fn decode(invoice_request_hex: String) -> Result<Self, BoltzError> {
        let invoice_req_buf = hex::decode(invoice_request_hex)
            .map_err(|e| BoltzError::new("InvoiceRequestHexDecode".to_string(), e.to_string()))?;
        let invoice_request = InvoiceRequest::try_from(invoice_req_buf)
            .map_err(|e| BoltzError::new("InvoiceRequestParse".to_string(), format!("{:?}", e)))?;

        Ok(DecodedBolt12InvoiceRequest {
            amount_msats: invoice_request.amount_msats(),
            network: match invoice_request.chain() {
                ChainHash::BITCOIN => Network::Mainnet,
                ChainHash::REGTEST => Network::Regtest,
                _ => Network::Testnet,
            },
            payer_signing_key: invoice_request.payer_signing_pubkey().to_string(),
            payer_note: invoice_request.payer_note().map(|p| p.to_string()),
            quantity: invoice_request.quantity(),
        })
    }
}

/// An [`EntropySource`] that always returns the same 32 bytes. Used only to make
/// the blinded-path session key predictable so [`strip_receive_auth`] can
/// recompute the final hop's encryption key. It is called exactly once per path
/// build (LDK derives everything else deterministically from the session key).
struct KnownEntropy([u8; 32]);

impl EntropySource for KnownEntropy {
    fn get_secure_random_bytes(&self) -> [u8; 32] {
        self.0
    }
}

fn entropy_source() -> RandomBytes {
    let mut entropy_bytes = [0u8; 32];
    thread_rng().fill_bytes(&mut entropy_bytes);
    RandomBytes::new(entropy_bytes)
}

/// Rewrites the terminating hop of a one-hop [`BlindedMessagePath`] so its
/// `encrypted_payload` is sealed the standard BOLT-04 way (ChaCha20-Poly1305,
/// all-zero nonce, **empty AAD**) instead of lightning 0.2.x's
/// `ReceiveAuthKey`-swapped-AAD form.
///
/// The ciphertext is byte-identical between the two forms — the auth key only
/// feeds the Poly1305 tag, never the ChaCha20 keystream — so we keep LDK's
/// ciphertext verbatim and recompute only the trailing 16-byte tag. This is
/// required because the path terminates at Boltz's CLN node, which decrypts with
/// `crypto_aead_chacha20poly1305_ietf_decrypt(..., ad = NULL, adlen = 0, ...)`.
fn strip_receive_auth(
    path: BlindedMessagePath,
    cln: &PublicKey,
    session_priv: &SecretKey,
) -> BlindedMessagePath {
    let hops = path.blinded_hops();
    assert_eq!(
        hops.len(),
        1,
        "one_hop path must have exactly one blinded hop"
    );
    let hop = &hops[0];

    // Strip LDK's 16-byte tag; the remainder is the (auth-key-independent) ciphertext.
    let ciphertext = &hop.encrypted_payload[..hop.encrypted_payload.len() - 16];

    // rho = HMAC-SHA256("rho", ECDH(session_priv, cln)); identical to LDK and CLN.
    // For a one-hop path the hop's blinding secret is the session key itself.
    let shared_secret = SharedSecret::new(cln, session_priv);
    let mut engine = HmacEngine::<sha256::Hash>::new(b"rho");
    engine.input(&shared_secret.secret_bytes());
    let rho = Hmac::<sha256::Hash>::from_engine(engine).to_byte_array();

    let mut encrypted_payload = Vec::with_capacity(hop.encrypted_payload.len());
    encrypted_payload.extend_from_slice(ciphertext);
    encrypted_payload.extend_from_slice(&poly1305_tag_empty_aad(&rho, ciphertext));

    BlindedMessagePath::from_blinded_path(
        *cln,
        path.blinding_point(),
        vec![BlindedHop {
            blinded_node_id: hop.blinded_node_id,
            encrypted_payload,
        }],
    )
}

/// Computes the ChaCha20-Poly1305 tag over `ciphertext` with an empty AAD,
/// exactly as libsodium's IETF construction (and LDK's non-AAD path) do, so the
/// result validates in Core Lightning's `decrypt_encmsg_raw`.
fn poly1305_tag_empty_aad(rho: &[u8; 32], ciphertext: &[u8]) -> [u8; 16] {
    use chacha20::cipher::{KeyIvInit, StreamCipher};
    use poly1305::universal_hash::{KeyInit, UniversalHash};

    // Poly1305 one-time key = first 32 bytes of the ChaCha20(rho, nonce=0) keystream.
    let mut keystream = [0u8; 64];
    chacha20::ChaCha20::new(
        chacha20::Key::from_slice(rho),
        chacha20::Nonce::from_slice(&[0u8; 12]),
    )
    .apply_keystream(&mut keystream);

    // MAC input: ciphertext || pad-to-16 || le64(aad_len = 0) || le64(ciphertext_len).
    let mut mac_input = ciphertext.to_vec();
    let remainder = mac_input.len() % 16;
    if remainder != 0 {
        mac_input.resize(mac_input.len() + (16 - remainder), 0);
    }
    mac_input.extend_from_slice(&0u64.to_le_bytes());
    mac_input.extend_from_slice(&(ciphertext.len() as u64).to_le_bytes());

    let mut mac = poly1305::Poly1305::new(poly1305::Key::from_slice(&keystream[..32]));
    mac.update_padded(&mac_input);

    let tag = mac.finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(tag.as_slice());
    out
}

impl BoltzManager {
    #[instrument(err, skip_all, fields(network))]
    // returns list of offers (walletId, offer)[]
    pub async fn create_bolt12_offer(
        self,
        network: Network,
        params: Vec<Bolt12OfferCreationParam>,
    ) -> Result<Vec<(LiquidWallet, String, KeyPair)>, BoltzError> {
        let nodes = self
            .api_config
            .get_boltz_client(&network)
            .get_nodes()
            .await?;
        let Some(node) = nodes.btc.get("CLN") else {
            return Err(BoltzError::new(
                "bolt12".to_string(),
                "Failed to get boltz's cln node id".to_string(),
            ));
        };
        let boltz_cln_pub_key = node.public_key;
        let secp = Secp256k1::new();

        let build_offer =
            |param: Bolt12OfferCreationParam| -> Result<(LiquidWallet, String, KeyPair), BoltzError> {
                let signing_key_pair: Keypair = MasterSwapKey::from_mnemonic(
                        param.liquid_wallet.swap_mnemonic.clone(),
                        None,
                        network.into()
                    )?
                    .get_bolt12_signing_key(0)?.try_into()?;

                let message_context = MessageContext::Offers(OffersContext::InvoiceRequest {
                    nonce: Nonce::from_entropy_source(&entropy_source()),
                });

                // We feed LDK a known session key (see `KnownEntropy`) so that afterwards we
                // can re-derive the blinded hop's `rho` and rewrite its authentication tag.
                // lightning 0.2.x authenticates the final message hop with a `ReceiveAuthKey`
                // AAD, which is an LDK-only extension that Boltz's CLN node (the node this
                // path terminates at) cannot decrypt — it decrypts `encrypted_recipient_data`
                // per BOLT-04 with an empty AAD. `strip_receive_auth` swaps that tag for a
                // standard one so the offer is fetchable by real CLN nodes.
                let mut session_bytes = [0u8; 32];
                thread_rng().fill_bytes(&mut session_bytes);
                SecretKey::new(&mut thread_rng());
                let session_priv = SecretKey::from_slice(&session_bytes).expect("valid session key");

                // The ReceiveAuthKey value is irrelevant: it only affects the tag, which we
                // overwrite below. Pass zeros.
                let path = BlindedMessagePath::one_hop(
                    boltz_cln_pub_key,
                    ReceiveAuthKey([0u8; 32]),
                    message_context,
                    &KnownEntropy(session_bytes),
                    &secp,
                );
                let path = strip_receive_auth(path, &boltz_cln_pub_key, &session_priv);

                let chain = match network {
                    Network::Mainnet => Bitcoin,
                    Network::Testnet => Testnet,
                    Network::Regtest => Regtest,
                };
                let mut offer_builder = OfferBuilder::new(PublicKey::from_keypair(&signing_key_pair))
                    .chain(chain)
                    .path(path);


                if let Some(description) = param.description {
                    offer_builder = offer_builder.description(description);
                }
                if let Some(issuer_name) = param.issuer_name {
                    offer_builder = offer_builder.issuer(issuer_name);
                }

                let offer = offer_builder
                    .build()
                    .map_err(|e| BoltzError::new("bolt12".to_string(), format!("{:?}", e)))?;
                Ok((param.liquid_wallet, offer.to_string(), signing_key_pair.into()))
            };

        params.into_iter().map(|param| build_offer(param)).collect()
    }

    #[instrument(err, skip_all, fields(network))]
    // returns bolt12 Invoice and address signature
    pub async fn create_bol12_invoice(
        self,
        offer_str: String,
        invoice_request_hex: String,
        signing_key: KeyPair,
        network: Network,
        preimage_hash: String,
        liquid_address: String,
    ) -> Result<(String, String), BoltzError> {
        let secp_ctx = Secp256k1::new();

        let offer = offer_str
            .parse::<Offer>()
            .map_err(|e| MannaError::new(format!("Failed to parse Offer: {:?}", e)))?;
        let invoice_req_bytes = hex::decode(invoice_request_hex)
            .map_err(|e| BoltzError::new("InvoiceRequestHexDecode".to_string(), e.to_string()))?;
        let invoice_request = InvoiceRequest::try_from(invoice_req_bytes)
            .map_err(|e| BoltzError::new("InvoiceRequestParse".to_string(), format!("{:?}", e)))?;

        let boltz_client = self.api_config.get_boltz_client(&network);
        let nodes = boltz_client.get_nodes().await?;
        let Some(node) = nodes.btc.get("CLN") else {
            return Err(BoltzError::new(
                "bolt12Invoice".to_string(),
                "Failed to get boltz's cln node id".to_string(),
            ));
        };
        let boltz_cln_pub_key = node.public_key;
        let invoice_param = boltz_client.get_bolt12_params().await?;

        let keypair: Keypair = signing_key.try_into()?;
        let preimage_hash: [u8; 32] = hex::decode(preimage_hash)
            .map_err(|e| BoltzError::new("hexDecodePreimageHash".to_string(), e.to_string()))?
            .try_into()
            .map_err(|_| BoltzError::new("vecToArray".to_string(), "".to_string()))?;

        let mut entropy_bytes = [0u8; 32];
        thread_rng().fill_bytes(&mut entropy_bytes);
        let entropy_source = RandomBytes::new(entropy_bytes);
        let nonce = Nonce::from_entropy_source(&entropy_source);

        let payment_context = PaymentContext::Bolt12Offer(Bolt12OfferContext {
            offer_id: offer.id(),
            invoice_request: InvoiceRequestFields {
                payer_signing_pubkey: invoice_request.payer_signing_pubkey(),
                quantity: invoice_request.quantity(),
                payer_note_truncated: invoice_request
                    .payer_note()
                    .map(|s| UntrustedString(s.to_string())),
                human_readable_name: invoice_request.offer_from_hrn().clone(),
            },
        });

        let mut payment_secret = [0u8; 32];
        thread_rng().fill_bytes(&mut payment_secret);

        let payee_tlvs = UnauthenticatedReceiveTlvs {
            payment_secret: PaymentSecret(payment_secret),
            payment_constraints: PaymentConstraints {
                max_cltv_expiry: 1_000_000,
                htlc_minimum_msat: 1,
            },
            payment_context,
        };

        let expanded_key = ExpandedKey::new(keypair.secret_key().secret_bytes());
        let authenticated_tlvs = payee_tlvs.authenticate(nonce, &expanded_key);

        let blinded_hop = BlindedPaymentPath::one_hop(
            boltz_cln_pub_key,
            authenticated_tlvs,
            invoice_param.min_cltv as u16,
            &entropy_source,
            &secp_ctx,
        )
        .map_err(|_| BoltzError::new("bolt12Invoice".to_string(), "".to_string()))?;

        let invoice = invoice_request
            .respond_with(vec![blinded_hop], PaymentHash(preimage_hash))
            .map_err(|e| BoltzError::new("bolt12InvoiceLinking".to_string(), format!("{:?}", e)))?
            .build()
            .map_err(|e| BoltzError::new("bolt12InvoiceLinking".to_string(), format!("{:?}", e)))?
            .sign(|msg: &UnsignedBolt12Invoice| {
                Ok(secp_ctx.sign_schnorr_no_aux_rand(msg.as_ref().as_digest(), &keypair))
            })
            .map_err(|e| BoltzError::new("bolt12InvoiceSigning".to_string(), format!("{:?}", e)))?;

        let mut writer = Vec::new();
        invoice
            .write(&mut writer)
            .map_err(|e| BoltzError::new("bolt12InvoiceWrite".to_string(), e.to_string()))?;

        let hrp = Hrp::parse("lni")
            .map_err(|e| BoltzError::new("hrpParse".to_string(), e.to_string()))?;
        let invoice_str = bech32::encode::<NoChecksum>(hrp, &writer)
            .map_err(|e| BoltzError::new("bech32Write".to_string(), e.to_string()))?;

        let address_hash = sha256::Hash::hash(liquid_address.as_bytes());
        let msg = Message::from_digest_slice(address_hash.as_byte_array())
            .map_err(|e| BoltzError::new("sha256".to_string(), e.to_string()))?;
        let address_signature = secp_ctx
            .sign_schnorr_no_aux_rand(&msg, &keypair)
            .serialize()
            .to_hex();

        Ok((invoice_str, address_signature))
    }

    #[instrument(err, skip_all, fields(network))]
    /// returns (invoice, Magic routing hint bip21)
    pub async fn generate_bolt12_invoice_for_send(
        self,
        network: Network,
        offer: String,
        amount: u64,
        note: Option<String>,
    ) -> Result<(String, Option<String>), BoltzError> {
        let decode_offer = decode_bolt12_offer(offer.clone())?;
        if decode_offer.is_expired || !decode_offer.networks.contains(&network) {
            return Err(BoltzError::new(
                "offer".to_string(),
                "Invalid BOLT12 offer".to_string(),
            ));
        }

        let parsed_offer: Offer = offer.parse().map_err(|_| {
            BoltzError::new(
                "offer".to_string(),
                "Failed to parse BOLT12 offer".to_string(),
            )
        })?;

        let bolt12invoice_res = self
            .api_config
            .get_boltz_client(&network)
            .get_bolt12_invoice(GetBolt12FetchRequest {
                offer,
                amount,
                note,
            })
            .await?;
        let bolt12_invoice_str = bolt12invoice_res.invoice;

        let invoice = parse_bolt12_invoice(bolt12_invoice_str.clone())?;

        // Validate that invoice belongs to the offer.
        let mut possible_signers: Vec<PublicKey> = Vec::new();

        if let Some(signer) = parsed_offer.issuer_signing_pubkey() {
            possible_signers.push(signer);
        }

        for path in parsed_offer.paths() {
            if let Some(last_hop) = path.blinded_hops().last() {
                possible_signers.push(last_hop.blinded_node_id);
            }
        }

        if !possible_signers.contains(&invoice.signing_pubkey()) {
            return Err(BoltzError::new(
                "validation".to_string(),
                "Invoice is not valid for the given offer".to_string(),
            ));
        }

        Ok((
            bolt12_invoice_str,
            bolt12invoice_res.magic_routing_hint.map(|i| i.bip21),
        ))
    }
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
    let p = CheckedHrpstring::new::<NoChecksum>(&invoice)
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

// returns schnorr signature of Sha256(data)
pub fn sign_schnorr(data: String, signing_key: KeyPair) -> Result<String, BoltzError> {
    let secp = Secp256k1::new();
    let msg = Message::from_digest_slice(sha256::Hash::hash(data.as_bytes()).as_byte_array())
        .map_err(|e| BoltzError::new("sha256".to_string(), e.to_string()))?;

    Ok(secp
        .sign_schnorr_no_aux_rand(&msg, &signing_key.try_into()?)
        .serialize()
        .to_hex())
}
