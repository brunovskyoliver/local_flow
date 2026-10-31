//! A scripted server end for tests: real HPKE, so what it answers goes through the real `Channel`.
//! Each `open` serves the next connection from the same list of replies.
use super::channel::*;
use crate::settings::base64url_decode;
use hpke::{Deserializable, Kem as _, OpModeR, OpModeS, Serializable, aead::ChaCha20Poly1305 as Aead, kdf::HkdfSha256 as Kdf, kem::X25519HkdfSha256 as Kem};
use rand_core::{OsRng, TryRngCore};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub enum Reply {
    Json(Value),
    Close(u16),
    Fail(TransportError),
    Text,
    /// A binary frame that won't open.
    Garbage,
}
impl Reply {
    pub fn ready() -> Reply {
        Reply::Json(json!({"schema_version": 1, "type": "ready"}))
    }
    pub fn error(code: &str) -> Reply {
        Reply::Json(json!({"schema_version": 1, "type": "error", "code": code}))
    }
    pub fn enrolled(state: &str, refresh: Option<&str>) -> Reply {
        let mut m = json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": state});
        if let Some(r) = refresh {
            m["refresh_token"] = r.into();
        }
        Reply::Json(m)
    }
    pub fn tokens(access: &str, refresh: &str) -> Reply {
        Reply::Json(json!({"schema_version": 1, "type": "tokens", "op": 1, "access_token": access, "expires_in": 900, "refresh_token": refresh}))
    }
}

#[derive(Default)]
struct Seen {
    opened: usize,
    closed: usize,
    messages: Vec<Value>,
    binding: [u8; 32],
}

#[derive(Clone)]
pub struct Counters(Arc<Mutex<Seen>>);
impl Counters {
    pub fn opened(&self) -> usize {
        self.0.lock().unwrap().opened
    }
    pub fn closed(&self) -> usize {
        self.0.lock().unwrap().closed
    }
    /// Every decrypted client message, hello included.
    pub fn messages(&self) -> Vec<Value> {
        self.0.lock().unwrap().messages.clone()
    }
    pub fn binding(&self) -> [u8; 32] {
        self.0.lock().unwrap().binding
    }
}

pub struct Script {
    private: Vec<u8>,
    public: Vec<u8>,
    replies: Arc<Mutex<VecDeque<Reply>>>,
    seen: Arc<Mutex<Seen>>,
}

impl Script {
    pub fn new(replies: Vec<Reply>) -> Script {
        let (private, public) = Kem::gen_keypair(&mut OsRng.unwrap_err());
        Script { private: private.to_bytes().to_vec(), public: public.to_bytes().to_vec(), replies: Arc::new(Mutex::new(replies.into())), seen: Default::default() }
    }
    pub fn public_key(&self) -> Vec<u8> {
        self.public.clone()
    }
    pub fn counters(&self) -> Counters {
        Counters(self.seen.clone())
    }
    pub fn push(&self, reply: Reply) {
        self.replies.lock().unwrap().push_back(reply);
    }
}

impl Transports for Script {
    fn open(&self, _: &str) -> Result<Box<dyn Transport>, TransportError> {
        self.seen.lock().unwrap().opened += 1;
        Ok(Box::new(End { private: self.private.clone(), replies: self.replies.clone(), seen: self.seen.clone(), receiver: None, sender: None, enc: None, send_seq: 0 }))
    }
}

struct End {
    private: Vec<u8>,
    replies: Arc<Mutex<VecDeque<Reply>>>,
    seen: Arc<Mutex<Seen>>,
    receiver: Option<hpke::aead::AeadCtxR<Aead, Kdf, Kem>>,
    sender: Option<hpke::aead::AeadCtxS<Aead, Kdf, Kem>>,
    enc: Option<Vec<u8>>,
    send_seq: u64,
}

impl Transport for End {
    fn send(&mut self, frame: &[u8]) -> Result<(), TransportError> {
        let plain = if self.receiver.is_none() {
            let private = <Kem as hpke::Kem>::PrivateKey::from_bytes(&self.private).unwrap();
            let enc = <Kem as hpke::Kem>::EncappedKey::from_bytes(&frame[4..36]).unwrap();
            let mut receiver = hpke::setup_receiver::<Aead, Kdf, Kem>(&OpModeR::Base, &private, &enc, b"localflow remote v1").unwrap();
            let plain = receiver.open(&frame[44..], &[&frame[..4], &frame[36..44]].concat()).unwrap();
            let hello: Value = serde_json::from_slice(&plain).unwrap();
            let reply_key = <Kem as hpke::Kem>::PublicKey::from_bytes(&base64url_decode(hello["reply_key"].as_str().unwrap()).unwrap()).unwrap();
            let mut s2c = [0; 32];
            receiver.export(b"localflow v1 s2c info", &mut s2c).unwrap();
            receiver.export(b"localflow v1 binding", &mut self.seen.lock().unwrap().binding).unwrap();
            let (enc_s2c, sender) = hpke::setup_sender::<Aead, Kdf, Kem, _>(&OpModeS::Base, &reply_key, &s2c, &mut OsRng.unwrap_err()).unwrap();
            self.sender = Some(sender);
            self.enc = Some(enc_s2c.to_bytes().to_vec());
            self.receiver = Some(receiver);
            plain
        } else {
            let mut plain = self.receiver.as_mut().unwrap().open(&frame[8..], &frame[..8]).unwrap();
            plain.remove(0);
            plain
        };
        self.seen.lock().unwrap().messages.push(serde_json::from_slice(&plain).unwrap());
        Ok(())
    }
    fn receive(&mut self) -> Result<Received, TransportError> {
        match self.replies.lock().unwrap().pop_front().unwrap_or(Reply::Close(1000)) {
            Reply::Json(m) => {
                let seq = self.send_seq.to_be_bytes();
                let plain = [&[0u8][..], m.to_string().as_bytes()].concat();
                let sealed = self.sender.as_mut().expect("the hello came first").seal(&plain, &seq).unwrap();
                self.send_seq += 1;
                Ok(Received::Binary([self.enc.take().unwrap_or_default().as_slice(), &seq, &sealed].concat()))
            }
            Reply::Close(code) => Err(TransportError::Closed(code)),
            Reply::Fail(e) => Err(e),
            Reply::Text => Ok(Received::Text),
            Reply::Garbage => Ok(Received::Binary(vec![9; 64])),
        }
    }
    fn close(&mut self) {
        self.seen.lock().unwrap().closed += 1;
    }
}
