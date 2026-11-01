//! One encrypted channel over a WebSocket (`contracts/remote-channel.md`, `RemoteChannel.swift`).
//! Blocking, on background threads: a send returns when the socket took the frame, so the write
//! timeout does what Swift's outbox and stall watchdog do.
use super::address;
use crate::settings::{Capabilities, base64url_encode};
use hpke::{Deserializable, Kem as _, OpModeR, OpModeS, Serializable, aead::AeadCtxR, aead::AeadCtxS, aead::ChaCha20Poly1305 as Aead, kdf::HkdfSha256 as Kdf, kem::X25519HkdfSha256 as Kem};
use rand_core::{OsRng, TryRngCore};
use serde_json::Value;
use std::time::{Duration, Instant};

pub const MAX_FRAME: usize = 70_000;
pub const MAX_CONTROL: usize = 65_536;
const INFO: &[u8] = b"localflow remote v1";
const MAGIC: &[u8] = b"LFR1";
type PrivateKey = <Kem as hpke::Kem>::PrivateKey;
type PublicKey = <Kem as hpke::Kem>::PublicKey;
type EncappedKey = <Kem as hpke::Kem>::EncappedKey;

/// Why a channel ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChannelError {
    /// The server couldn't open the hello (close code 4001): not the pinned server.
    PinMismatch,
    Unreachable,
    Timeout,
    /// A frame out of sequence, one that didn't open, a text message or bad JSON.
    Protocol,
    /// The server's `error.code`.
    Server(String),
    Closed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportError {
    Closed(u16),
    Timeout,
    Unreachable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Received {
    Binary(Vec<u8>),
    Text,
}

pub trait Transport: Send {
    fn send(&mut self, frame: &[u8]) -> Result<(), TransportError>;
    fn receive(&mut self) -> Result<Received, TransportError>;
    /// `receive` that answers at once with `None` when nothing has come.
    fn try_receive(&mut self) -> Result<Option<Received>, TransportError> {
        self.receive().map(Some)
    }
    fn close(&mut self);
}

/// `RemoteTransportOpening`.
pub trait Transports: Send + Sync {
    fn open(&self, url: &str) -> Result<Box<dyn Transport>, TransportError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    Enroll,
    Refresh,
    Session,
}
impl Purpose {
    fn as_str(self) -> &'static str {
        match self {
            Purpose::Enroll => "enroll",
            Purpose::Refresh => "refresh",
            Purpose::Session => "session",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Control = 0,
    Audio = 1,
    /// Feature 018: meeting windows as 16 kHz mono s16le.
    AudioS16 = 2,
}

/// The HPKE contexts and frame counters of one channel, without a socket.
pub struct Crypto {
    sender: AeadCtxS<Aead, Kdf, Kem>,
    enc: Vec<u8>,
    recipient: Option<AeadCtxR<Aead, Kdf, Kem>>,
    reply_key: PrivateKey,
    pub reply_public: Vec<u8>,
    send_seq: u64,
    receive_seq: u64,
    pub binding: [u8; 32],
    s2c_info: [u8; 32],
}

impl Crypto {
    pub fn new(server_key: &[u8]) -> Result<Crypto, ChannelError> {
        let (private, public) = Kem::gen_keypair(&mut OsRng.unwrap_err());
        Crypto::with_reply_key(server_key, private, public)
    }

    fn with_reply_key(server_key: &[u8], reply_key: PrivateKey, reply_public: PublicKey) -> Result<Crypto, ChannelError> {
        // A key that can't be one is what a mismatch is: this isn't that server.
        let key = PublicKey::from_bytes(server_key).map_err(|_| ChannelError::PinMismatch)?;
        let (enc, sender) = hpke::setup_sender::<Aead, Kdf, Kem, _>(&OpModeS::Base, &key, INFO, &mut OsRng.unwrap_err()).map_err(|_| ChannelError::Protocol)?;
        let (mut binding, mut s2c_info) = ([0; 32], [0; 32]);
        sender.export(b"localflow v1 binding", &mut binding).map_err(|_| ChannelError::Protocol)?;
        sender.export(b"localflow v1 s2c info", &mut s2c_info).map_err(|_| ChannelError::Protocol)?;
        Ok(Crypto { sender, enc: enc.to_bytes().to_vec(), recipient: None, reply_key, reply_public: reply_public.to_bytes().to_vec(), send_seq: 0, receive_seq: 0, binding, s2c_info })
    }

    /// `"LFR1" | enc | seq = 0 | Seal(aad = "LFR1" ‖ seq, hello JSON)`.
    pub fn hello_frame(&mut self, hello: &[u8]) -> Result<Vec<u8>, ChannelError> {
        let seq = 0u64.to_be_bytes();
        let sealed = self.sender.seal(hello, &[MAGIC, &seq].concat()).map_err(|_| ChannelError::Protocol)?;
        self.send_seq = 1;
        Ok([MAGIC, &self.enc, &seq, &sealed].concat())
    }

    /// `seq | Seal(aad = seq, kind ‖ payload)`.
    pub fn seal(&mut self, kind: Kind, payload: &[u8]) -> Result<Vec<u8>, ChannelError> {
        let seq = self.send_seq.to_be_bytes();
        let sealed = self.sender.seal(&[&[kind as u8], payload].concat(), &seq).map_err(|_| ChannelError::Protocol)?;
        self.send_seq += 1;
        let frame = [&seq[..], &sealed].concat();
        if frame.len() > MAX_FRAME { Err(ChannelError::Protocol) } else { Ok(frame) }
    }

    /// Opens a server frame, the first of which carries `enc_s2c`. Returns the control JSON.
    pub fn open(&mut self, frame: &[u8]) -> Result<Vec<u8>, ChannelError> {
        if frame.len() > MAX_FRAME {
            return Err(ChannelError::Protocol);
        }
        let mut body = frame;
        if self.recipient.is_none() {
            if body.len() <= 40 {
                return Err(ChannelError::Protocol);
            }
            let enc = EncappedKey::from_bytes(&body[..32]).map_err(|_| ChannelError::Protocol)?;
            self.recipient = Some(hpke::setup_receiver::<Aead, Kdf, Kem>(&OpModeR::Base, &self.reply_key, &enc, &self.s2c_info).map_err(|_| ChannelError::Protocol)?);
            body = &body[32..];
        }
        if body.len() <= 8 || body[..8] != self.receive_seq.to_be_bytes() {
            return Err(ChannelError::Protocol);
        }
        let plain = self.recipient.as_mut().ok_or(ChannelError::Protocol)?.open(&body[8..], &body[..8]).map_err(|_| ChannelError::Protocol)?;
        self.receive_seq += 1;
        // The server sends control messages only.
        match plain.split_first() {
            Some((0, json)) if json.len() <= MAX_CONTROL => Ok(json.to_vec()),
            _ => Err(ChannelError::Protocol),
        }
    }
}

/// A message from the server. Only what enrollment reads has a type of its own so far; the handoff
/// and dictation answers stay as JSON for their features.
#[derive(Clone, Debug, PartialEq)]
pub enum ServerMessage {
    Ready(Option<Capabilities>),
    Enrolled { op: i64, state: String, refresh_token: Option<String> },
    Tokens { op: i64, access_token: String, refresh_token: String },
    Error { code: String },
    Other(Value),
}

pub fn decode(json: &[u8]) -> Result<ServerMessage, ChannelError> {
    let bad = ChannelError::Protocol;
    let object: Value = serde_json::from_slice(json).map_err(|_| ChannelError::Protocol)?;
    let (Some(version), Some(kind)) = (object.get("schema_version").and_then(Value::as_i64), object.get("type").and_then(Value::as_str)) else { return Err(bad) };
    if version != 1 {
        return Err(ChannelError::Server("unsupported_version".into()));
    }
    let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
    let op = object.get("op").and_then(Value::as_i64).filter(|o| (1..=i64::from(i32::MAX)).contains(o));
    Ok(match kind {
        "ready" => ServerMessage::Ready(object.get("capabilities").and_then(|c| serde_json::from_value(c.clone()).ok())),
        "enrolled" => {
            let (op, state) = (op.ok_or(ChannelError::Protocol)?, text("state").ok_or(ChannelError::Protocol)?);
            let refresh_token = text("refresh_token");
            // A rejected identity gets no refresh token; every other state gets one.
            if !["pending", "approved", "rejected"].contains(&state.as_str()) || (state == "rejected") != refresh_token.is_none() {
                return Err(bad);
            }
            ServerMessage::Enrolled { op, state, refresh_token }
        }
        "tokens" => {
            object.get("expires_in").and_then(Value::as_i64).ok_or(ChannelError::Protocol)?;
            ServerMessage::Tokens { op: op.ok_or(ChannelError::Protocol)?, access_token: text("access_token").ok_or(ChannelError::Protocol)?, refresh_token: text("refresh_token").ok_or(bad)? }
        }
        "error" => ServerMessage::Error { code: text("code").ok_or(bad)? },
        _ => ServerMessage::Other(object),
    })
}

/// One channel: hello, then sequential operations. The first failure sticks and closes the socket.
pub struct Channel {
    transport: Box<dyn Transport>,
    crypto: Crypto,
    failure: Option<ChannelError>,
    closed: bool,
    /// `ready` opened, so the server holds the pinned key: a later 4001 isn't a mismatch.
    ready: bool,
    /// What the server offered in `ready`.
    pub capabilities: Option<Capabilities>,
}

impl Channel {
    pub fn new(transport: Box<dyn Transport>, server_key: &[u8]) -> Result<Channel, ChannelError> {
        Ok(Channel { transport, crypto: Crypto::new(server_key)?, failure: None, closed: false, ready: false, capabilities: None })
    }

    /// The exporter value that binds signatures and the OIDC nonce to this channel.
    pub fn binding(&self) -> [u8; 32] {
        self.crypto.binding
    }

    /// Sends the hello and waits for `ready`. A server `error` fails with `Server(code)`.
    pub fn open(&mut self, purpose: Purpose, access_token: Option<&str>) -> Result<(), ChannelError> {
        let mut hello = serde_json::json!({"schema_version": 1, "type": "hello", "reply_key": base64url_encode(&self.crypto.reply_public), "purpose": purpose.as_str()});
        if let Some(token) = access_token {
            hello["access_token"] = token.into();
        }
        let frame = self.crypto.hello_frame(hello.to_string().as_bytes())?;
        self.send_frame(&frame)?;
        match self.receive()? {
            ServerMessage::Ready(offered) => {
                self.ready = true;
                self.capabilities = offered;
                Ok(())
            }
            ServerMessage::Error { code } => Err(self.fail(ChannelError::Server(code))),
            _ => Err(self.fail(ChannelError::Protocol)),
        }
    }

    /// A control message. Adds `schema_version`.
    pub fn send(&mut self, mut message: Value) -> Result<(), ChannelError> {
        message["schema_version"] = 1.into();
        self.send_json(&message.to_string())
    }

    /// A control message whose JSON is already written, for a body that must keep its exact bytes.
    pub fn send_json(&mut self, json: &str) -> Result<(), ChannelError> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        if json.len() > MAX_CONTROL {
            return Err(ChannelError::Protocol);
        }
        let frame = self.crypto.seal(Kind::Control, json.as_bytes()).map_err(|e| self.fail(e))?;
        self.send_frame(&frame)
    }

    /// One frame of f32le samples.
    pub fn send_audio(&mut self, samples: &[f32]) -> Result<(), ChannelError> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let frame = self.crypto.seal(Kind::Audio, &bytes).map_err(|e| self.fail(e))?;
        self.send_frame(&frame)
    }

    /// The next server message. Transport and framing failures close the channel.
    pub fn receive(&mut self) -> Result<ServerMessage, ChannelError> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        let received = self.transport.receive();
        self.opened(received)
    }

    /// `receive` for a loop that also sends: `None` when no message has come yet.
    pub fn poll(&mut self) -> Result<Option<ServerMessage>, ChannelError> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        match self.transport.try_receive() {
            Ok(None) => Ok(None),
            Ok(Some(received)) => self.opened(Ok(received)).map(Some),
            Err(e) => self.opened(Err(e)).map(Some),
        }
    }

    fn opened(&mut self, received: Result<Received, TransportError>) -> Result<ServerMessage, ChannelError> {
        let frame = match received {
            Ok(Received::Binary(frame)) => frame,
            Ok(Received::Text) => return Err(self.fail(ChannelError::Protocol)),
            // A close code is unauthenticated: anyone on the path can send one.
            Err(TransportError::Closed(4001)) if self.ready => return Err(self.fail(ChannelError::Closed)),
            Err(TransportError::Closed(4001)) => return Err(self.fail(ChannelError::PinMismatch)),
            Err(TransportError::Timeout) => return Err(self.fail(ChannelError::Timeout)),
            Err(_) => return Err(self.fail(ChannelError::Unreachable)),
        };
        let json = self.crypto.open(&frame).map_err(|e| self.fail(e))?;
        decode(&json).map_err(|e| self.fail(e))
    }

    fn send_frame(&mut self, frame: &[u8]) -> Result<(), ChannelError> {
        match self.transport.send(frame) {
            Ok(()) => Ok(()),
            Err(TransportError::Timeout) => Err(self.fail(ChannelError::Timeout)),
            Err(_) => Err(self.fail(ChannelError::Unreachable)),
        }
    }

    pub fn close(&mut self) {
        if !self.closed {
            self.closed = true;
            self.transport.close();
        }
        self.failure.get_or_insert(ChannelError::Closed);
    }

    /// Records the first failure and closes the socket; later calls see the same error.
    fn fail(&mut self, error: ChannelError) -> ChannelError {
        let first = self.failure.get_or_insert(error).clone();
        if !self.closed {
            self.closed = true;
            self.transport.close();
        }
        first
    }
}

impl Drop for Channel {
    fn drop(&mut self) {
        self.close();
    }
}

/// `wss://<host>/v1/remote/channel`, or `ws://` for an `http://` origin. `None` for anything
/// `address::origin` refuses, so a refused address never gets a socket.
pub fn channel_url(origin: &str) -> Option<String> {
    let checked = address::origin(origin)?;
    let socket = match checked.strip_prefix("https://") {
        Some(host) => format!("wss://{host}"),
        None => format!("ws://{}", checked.strip_prefix("http://")?),
    };
    Some(format!("{socket}/v1/remote/channel"))
}

struct WebSocket(tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>, Duration);

impl WebSocket {
    fn set_read_timeout(&mut self, timeout: Duration) -> Result<(), TransportError> {
        use tungstenite::stream::MaybeTlsStream;
        let tcp = match self.0.get_mut() {
            MaybeTlsStream::Plain(s) => s,
            MaybeTlsStream::Rustls(s) => &mut s.sock,
            _ => return Err(TransportError::Unreachable),
        };
        tcp.set_read_timeout(Some(timeout)).map_err(|_| TransportError::Unreachable)
    }
}

fn timed_out(e: &std::io::Error) -> bool {
    matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)
}

fn mapped(e: tungstenite::Error) -> TransportError {
    match e {
        tungstenite::Error::Io(e) if timed_out(&e) => TransportError::Timeout,
        _ => TransportError::Unreachable,
    }
}

impl Transport for WebSocket {
    fn send(&mut self, frame: &[u8]) -> Result<(), TransportError> {
        self.0.send(tungstenite::Message::binary(frame.to_vec())).map_err(mapped)
    }
    fn receive(&mut self) -> Result<Received, TransportError> {
        use tungstenite::Message;
        loop {
            match self.0.read().map_err(mapped)? {
                Message::Binary(b) => return Ok(Received::Binary(b.to_vec())),
                Message::Text(_) => return Ok(Received::Text),
                Message::Close(frame) => return Err(TransportError::Closed(frame.map_or(1005, |f| f.code.into()))),
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        }
    }
    /// A very short read timeout: tungstenite and rustls keep a partial frame for the next read.
    fn try_receive(&mut self) -> Result<Option<Received>, TransportError> {
        self.set_read_timeout(Duration::from_millis(1))?;
        let received = self.receive();
        self.set_read_timeout(self.1)?;
        match received {
            Err(TransportError::Timeout) => Ok(None),
            other => other.map(Some),
        }
    }
    fn close(&mut self) {
        let _ = self.0.close(None);
        let _ = self.0.flush();
    }
}

/// Real sockets. No cookies and no `Authorization` by construction, and no proxy.
pub struct WebSockets {
    pub connect_timeout: Duration,
    /// Idle time between received messages. Swift's is 45 s: well above the server's 15 s ping.
    pub read_timeout: Duration,
}

impl Default for WebSockets {
    fn default() -> Self {
        WebSockets { connect_timeout: Duration::from_secs(10), read_timeout: Duration::from_secs(45) }
    }
}

impl Transports for WebSockets {
    fn open(&self, url: &str) -> Result<Box<dyn Transport>, TransportError> {
        use std::net::{TcpStream, ToSocketAddrs};
        let authority = url.split_once("://").map_or("", |u| u.1).split('/').next().unwrap_or_default();
        let default_port = if url.starts_with("wss") { 443 } else { 80 };
        let (host, port) = match authority.strip_prefix('[') {
            Some(rest) => {
                let (h, tail) = rest.split_once(']').ok_or(TransportError::Unreachable)?;
                (h.replace("%25", "%"), tail.strip_prefix(':').and_then(|p| p.parse().ok()).unwrap_or(default_port))
            }
            None => match authority.rsplit_once(':') {
                Some((h, p)) => (h.to_string(), p.parse().map_err(|_| TransportError::Unreachable)?),
                None => (authority.to_string(), default_port),
            },
        };
        let addresses = (host.as_str(), port).to_socket_addrs().map_err(|_| TransportError::Unreachable)?;
        let mut last = TransportError::Unreachable;
        let stream = addresses
            .into_iter()
            .find_map(|address| match TcpStream::connect_timeout(&address, self.connect_timeout) {
                Ok(stream) => Some(stream),
                Err(e) => {
                    if timed_out(&e) {
                        last = TransportError::Timeout;
                    }
                    None
                }
            })
            .ok_or(last)?;
        stream.set_read_timeout(Some(self.read_timeout)).map_err(|_| TransportError::Unreachable)?;
        stream.set_write_timeout(Some(Duration::from_secs(15))).map_err(|_| TransportError::Unreachable)?;
        let config = tungstenite::protocol::WebSocketConfig::default().max_message_size(Some(MAX_FRAME)).max_frame_size(Some(MAX_FRAME));
        let (socket, _) = tungstenite::client_tls_with_config(url, stream, Some(config), None).map_err(|_| TransportError::Unreachable)?;
        Ok(Box::new(WebSocket(socket, self.read_timeout)))
    }
}

/// `RemoteChannelPool.roundTrip`: a fresh channel timed to `ready`, then closed. Returns the
/// milliseconds and what `ready` offered. `token` makes it a session hello; `None` is an enroll hello.
pub fn channel_round_trip(origin: &str, server_key: &[u8], token: Option<&str>) -> Result<(u128, Option<Capabilities>), ChannelError> {
    let url = channel_url(origin).ok_or(ChannelError::Unreachable)?;
    let sockets = WebSockets { connect_timeout: Duration::from_secs(10), read_timeout: Duration::from_secs(10) };
    let started = Instant::now();
    let transport = sockets.open(&url).map_err(|_| ChannelError::Unreachable)?;
    let mut channel = Channel::new(transport, server_key)?;
    channel.open(if token.is_some() { Purpose::Session } else { Purpose::Enroll }, token)?;
    Ok((started.elapsed().as_millis(), channel.capabilities.take()))
}

/// Swift's `ping()`: nil when this device has no pinned key or token, or the channel fails.
pub fn ping(origin: &str, server_key: Option<&[u8]>, token: Option<&str>) -> Option<(u128, Option<Capabilities>)> {
    channel_round_trip(origin, server_key?, Some(token?)).ok()
}

#[cfg(test)]
pub(crate) fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

#[cfg(test)]
mod tests {
    use super::super::scripted::{Reply, Script};
    use super::*;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../../../fixtures/remote/hpke-vectors.json")).unwrap()
    }
    fn hex(v: &Value) -> Vec<u8> {
        unhex(v.as_str().unwrap())
    }

    /// Server frames recorded by flowd open with the reply key and the exported `s2c_info`.
    #[test]
    fn vectors_server_frames_open_in_order() {
        let v = vectors();
        let reply_private = PrivateKey::from_bytes(&hex(&v["reply_private_key"])).unwrap();
        assert_eq!(<Kem as hpke::Kem>::sk_to_pk(&reply_private).to_bytes().to_vec(), hex(&v["reply_public_key"]));
        let build = || {
            let mut c = Crypto::with_reply_key(&hex(&v["server_public_key"]), PrivateKey::from_bytes(&hex(&v["reply_private_key"])).unwrap(), PublicKey::from_bytes(&hex(&v["reply_public_key"])).unwrap()).unwrap();
            c.s2c_info.copy_from_slice(&hex(&v["exports"]["s2c_info"]));
            c
        };
        let mut c = build();
        let plain = hex(&v["server_first"]["plaintext"]);
        assert_eq!(c.open(&hex(&v["server_first"]["frame"])).unwrap(), plain[1..], "kind byte removed");
        for (i, s2c) in v["s2c"].as_array().unwrap().iter().enumerate() {
            assert_eq!(s2c["seq"].as_u64(), Some(i as u64 + 1));
            if s2c["kind"] == "control" {
                assert_eq!(c.open(&hex(&s2c["frame"])).unwrap(), hex(&s2c["plaintext"])[1..]);
            }
        }
        // Out of sequence: frame 1 before the first; a flipped bit; a replay.
        let mut c = build();
        let first = hex(&v["server_first"]["frame"]);
        let mut wrong_seq = first.clone();
        wrong_seq[39] = 1;
        assert_eq!(c.open(&wrong_seq), Err(ChannelError::Protocol));
        let mut c = build();
        let mut flipped = first.clone();
        *flipped.last_mut().unwrap() ^= 1;
        assert_eq!(c.open(&flipped), Err(ChannelError::Protocol));
        let mut c = build();
        c.open(&first).unwrap();
        assert_eq!(c.open(&hex(&v["s2c"][0]["frame"])).is_ok(), v["s2c"][0]["kind"] == "control");
        assert_eq!(c.open(&hex(&v["s2c"][0]["frame"])), Err(ChannelError::Protocol), "a replay");
    }

    /// The recorded client frames open with the server's key under our layout and labels, and frames
    /// we seal open the same way. The sender's ephemeral key is random, so ours can't be byte-equal.
    #[test]
    fn vectors_client_frames_and_ours_open_at_the_server() {
        let v = vectors();
        let server = PrivateKey::from_bytes(&hex(&v["server_private_key"])).unwrap();
        let info = hex(&v["info"]);
        assert_eq!(info, INFO);
        let hello = hex(&v["hello"]["frame"]);
        let receiver = |frame: &[u8]| {
            assert_eq!(&frame[..4], MAGIC);
            let enc = EncappedKey::from_bytes(&frame[4..36]).unwrap();
            hpke::setup_receiver::<Aead, Kdf, Kem>(&OpModeR::Base, &server, &enc, INFO).unwrap()
        };
        let mut r = receiver(&hello);
        assert_eq!(r.open(&hello[44..], &hex(&v["hello"]["aad"])).unwrap(), hex(&v["hello"]["plaintext"]));
        let (mut s2c, mut binding) = ([0; 32], [0; 32]);
        r.export(b"localflow v1 s2c info", &mut s2c).unwrap();
        r.export(b"localflow v1 binding", &mut binding).unwrap();
        assert_eq!(s2c.to_vec(), hex(&v["exports"]["s2c_info"]));
        assert_eq!(binding.to_vec(), hex(&v["exports"]["binding"]));
        for c2s in v["c2s"].as_array().unwrap() {
            let frame = hex(&c2s["frame"]);
            assert_eq!(frame[..8], hex(&c2s["aad"]));
            assert_eq!(r.open(&frame[8..], &frame[..8]).unwrap(), hex(&c2s["plaintext"]));
        }

        let mut ours = Crypto::new(&hex(&v["server_public_key"])).unwrap();
        let frame = ours.hello_frame(b"{}").unwrap();
        let mut r = receiver(&frame);
        assert_eq!(r.open(&frame[44..], &[MAGIC, &[0; 8]].concat()).unwrap(), b"{}");
        let mut exported = [0; 32];
        r.export(b"localflow v1 binding", &mut exported).unwrap();
        assert_eq!(exported, ours.binding);
        for (seq, kind) in [(1u64, Kind::Control), (2, Kind::Audio), (3, Kind::AudioS16)] {
            let frame = ours.seal(kind, b"x").unwrap();
            assert_eq!(frame[..8], seq.to_be_bytes());
            assert_eq!(r.open(&frame[8..], &frame[..8]).unwrap(), [kind as u8, b'x']);
        }
        assert_eq!(ours.seal(Kind::Audio, &vec![0; MAX_FRAME]), Err(ChannelError::Protocol), "too big for a frame");
    }

    fn opened(script: Script, purpose: Purpose) -> (Result<(), ChannelError>, Channel) {
        let key = script.public_key();
        let mut channel = Channel::new(script.open("ws://x").unwrap(), &key).unwrap();
        (channel.open(purpose, None), channel)
    }

    #[test]
    fn hello_answers_map_to_errors() {
        let error = |script: Script| opened(script, Purpose::Enroll).0;
        assert_eq!(error(Script::new(vec![Reply::Close(4001)])), Err(ChannelError::PinMismatch));
        assert_eq!(error(Script::new(vec![Reply::Close(1006)])), Err(ChannelError::Unreachable));
        assert_eq!(error(Script::new(vec![Reply::Fail(TransportError::Timeout)])), Err(ChannelError::Timeout));
        assert_eq!(error(Script::new(vec![Reply::Text])), Err(ChannelError::Protocol));
        assert_eq!(error(Script::new(vec![Reply::Garbage])), Err(ChannelError::Protocol));
        assert_eq!(error(Script::new(vec![Reply::error("busy")])), Err(ChannelError::Server("busy".into())));
        assert_eq!(error(Script::new(vec![Reply::Json(serde_json::json!({"schema_version": 2, "type": "ready"}))])), Err(ChannelError::Server("unsupported_version".into())));
        assert_eq!(error(Script::new(vec![Reply::Json(serde_json::json!({"schema_version": 1, "type": "tokens"}))])), Err(ChannelError::Protocol));
    }

    #[test]
    fn a_4001_after_ready_is_a_plain_close() {
        let (result, mut channel) = opened(Script::new(vec![Reply::ready(), Reply::Close(4001)]), Purpose::Session);
        assert_eq!(result, Ok(()));
        assert_eq!(channel.receive(), Err(ChannelError::Closed));
    }

    #[test]
    fn the_first_failure_sticks_and_closes_the_socket() {
        let script = Script::new(vec![Reply::Close(4001)]);
        let counters = script.counters();
        let (result, mut channel) = opened(script, Purpose::Enroll);
        assert_eq!(result, Err(ChannelError::PinMismatch));
        assert_eq!(counters.closed(), 1);
        assert_eq!(channel.receive(), Err(ChannelError::PinMismatch));
        assert_eq!(channel.send(serde_json::json!({"type": "x"})), Err(ChannelError::PinMismatch));
        channel.close();
        drop(channel);
        assert_eq!(counters.closed(), 1, "closed once");
    }

    #[test]
    fn sequence_runs_across_operations_and_the_binding_matches_the_server() {
        let script = Script::new(vec![Reply::ready(), Reply::Json(serde_json::json!({"schema_version": 1, "type": "cancelled", "op": 1})), Reply::Json(serde_json::json!({"schema_version": 1, "type": "cancelled", "op": 2}))]);
        let counters = script.counters();
        let (result, mut channel) = opened(script, Purpose::Session);
        result.unwrap();
        for op in 1..=2 {
            channel.send(serde_json::json!({"type": "ping", "op": op})).unwrap();
            assert!(matches!(channel.receive().unwrap(), ServerMessage::Other(m) if m["op"] == op));
        }
        let seen = counters.messages();
        assert_eq!(seen[0]["purpose"], "session");
        assert_eq!(seen[1]["schema_version"], 1, "added on send");
        assert_eq!(seen[2]["op"], 2);
        assert_eq!(counters.binding(), channel.binding());
    }

    #[test]
    fn enrolled_and_tokens_must_be_well_formed() {
        let m = |v: Value| decode(v.to_string().as_bytes());
        let ok = serde_json::json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": "approved", "refresh_token": "lfr_x"});
        assert_eq!(m(ok), Ok(ServerMessage::Enrolled { op: 1, state: "approved".into(), refresh_token: Some("lfr_x".into()) }));
        assert_eq!(m(serde_json::json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": "rejected"})), Ok(ServerMessage::Enrolled { op: 1, state: "rejected".into(), refresh_token: None }));
        for bad in [
            serde_json::json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": "approved"}),
            serde_json::json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": "rejected", "refresh_token": "x"}),
            serde_json::json!({"schema_version": 1, "type": "enrolled", "op": 1, "state": "odd", "refresh_token": "x"}),
            serde_json::json!({"schema_version": 1, "type": "enrolled", "op": 0, "state": "approved", "refresh_token": "x"}),
            serde_json::json!({"schema_version": 1, "type": "tokens", "op": 1, "access_token": "a", "refresh_token": "r"}),
            serde_json::json!({"type": "ready"}),
        ] {
            assert_eq!(m(bad.clone()), Err(ChannelError::Protocol), "{bad}");
        }
        assert_eq!(decode(b"not json"), Err(ChannelError::Protocol));
    }

    #[test]
    fn a_key_that_cant_be_one_is_a_mismatch() {
        let script = Script::new(vec![]);
        assert!(matches!(Channel::new(script.open("ws://x").unwrap(), &[1, 2, 3]), Err(ChannelError::PinMismatch)));
    }

    #[test]
    fn a_refused_address_gets_no_socket() {
        assert_eq!(channel_round_trip("http://8.8.8.8", &[7; 32], None), Err(ChannelError::Unreachable));
        assert_eq!(channel_url("https://flow.example.com:8443/").as_deref(), Some("wss://flow.example.com:8443/v1/remote/channel"));
        assert_eq!(channel_url("http://127.0.0.1:9").as_deref(), Some("ws://127.0.0.1:9/v1/remote/channel"));
    }
}
