//! Google sign-in from the system browser (FR-007, research R6): authorization code with PKCE,
//! `state` and the channel-bound nonce. The browser returns to a listener bound to 127.0.0.1 only,
//! which lives for this one sign-in. A forged callback can't finish: it lacks `state`, and the code
//! is useless without the verifier. It doesn't end the wait either, so a local page can't cancel.
use super::Unavailable;
use crate::settings::{base64url_encode, sha256};
use rand_core::{OsRng, TryRngCore};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

const REFUSED: Unavailable = Unavailable("Google sign-in");
/// Plan, "Bounds and overload".
const MAX_REQUEST: usize = 8 * 1024;
const WAIT: Duration = Duration::from_secs(5 * 60);
/// A connection that stays silent can't hold up the real callback for longer than this.
const CONNECTION: Duration = Duration::from_secs(2);
const MAX_TOKEN_RESPONSE: u64 = 65_536;

pub struct GoogleClient {
    pub client_id: String,
    /// A Desktop client's secret isn't confidential by Google's design, and may be absent.
    pub client_secret: Option<String>,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub wait: Duration,
}

/// What came in on the loopback address.
#[derive(Debug, PartialEq, Eq)]
enum Callback {
    Code(String),
    /// Our `state` with an error, such as the user pressing Cancel on Google's page.
    Denied,
    /// Anything else: keep waiting.
    Ignored,
}

fn random_url_safe(bytes: usize) -> String {
    let mut data = vec![0; bytes];
    OsRng.try_fill_bytes(&mut data).expect("the OS random source");
    base64url_encode(&data)
}

fn challenge(verifier: &str) -> String {
    base64url_encode(&sha256(verifier.as_bytes()))
}

fn encode(value: &str) -> String {
    value.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

fn decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let (mut out, mut i) = (Vec::with_capacity(bytes.len()), 0);
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// Reads the request line of `GET /?…`. Only the root path counts, so a favicon request is ignored.
fn callback(request: &[u8], state: &str) -> Callback {
    let Some(line) = std::str::from_utf8(request).ok().and_then(|r| r.split("\r\n").next()) else { return Callback::Ignored };
    let Some(query) = line.strip_prefix("GET /?").and_then(|r| r.strip_suffix(" HTTP/1.1").or_else(|| r.strip_suffix(" HTTP/1.0"))) else { return Callback::Ignored };
    let value = |name: &str| query.split('&').find_map(|pair| pair.strip_prefix(name)?.strip_prefix('=')).and_then(decode);
    if value("state").as_deref() != Some(state) {
        return Callback::Ignored;
    }
    match value("code").filter(|c| !c.is_empty() && value("error").is_none()) {
        Some(code) => Callback::Code(code),
        None => Callback::Denied,
    }
}

/// One request head, up to `MAX_REQUEST` and until `by`. `None` when it never completes.
fn read_head(stream: &mut TcpStream, by: Instant) -> Option<Vec<u8>> {
    stream.set_nonblocking(false).ok()?;
    let mut head = Vec::with_capacity(1024);
    let mut chunk = [0; 1024];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let left = by.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())?;
        stream.set_read_timeout(Some(left)).ok()?;
        let n = stream.read(&mut chunk).ok().filter(|n| *n > 0)?;
        if head.len() + n > MAX_REQUEST {
            return None;
        }
        head.extend_from_slice(&chunk[..n]);
    }
    Some(head)
}

fn answer(stream: &mut TcpStream, status: &str, text: &str) {
    let page = format!("<!doctype html><meta charset=\"utf-8\"><title>LocalFlow</title><p>{text}</p>");
    let _ = write!(stream, "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n{page}", page.len());
}

/// One connection at a time, until a callback carrying `state` or the deadline. The listener is
/// dropped by the caller right after, so nothing listens once this returns.
fn wait_for_code(listener: &TcpListener, state: &str, by: Instant) -> Result<String, Unavailable> {
    listener.set_nonblocking(true).map_err(|_| REFUSED)?;
    while Instant::now() < by {
        let mut stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
            Err(_) => return Err(REFUSED),
        };
        let found = read_head(&mut stream, by.min(Instant::now() + CONNECTION)).map_or(Callback::Ignored, |head| callback(&head, state));
        match found {
            Callback::Code(code) => {
                answer(&mut stream, "200 OK", "You're signed in. You can close this window and go back to LocalFlow.");
                return Ok(code);
            }
            Callback::Denied => {
                answer(&mut stream, "200 OK", "Sign-in was cancelled. You can close this window.");
                return Err(REFUSED);
            }
            Callback::Ignored => answer(&mut stream, "400 Bad Request", "This address only answers LocalFlow's sign-in."),
        }
    }
    Err(REFUSED)
}

impl GoogleClient {
    pub fn new(client_id: &str, client_secret: Option<&str>) -> GoogleClient {
        GoogleClient {
            client_id: client_id.into(),
            client_secret: client_secret.map(Into::into),
            authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth".into(),
            token_endpoint: "https://oauth2.googleapis.com/token".into(),
            wait: WAIT,
        }
    }

    fn authorization_url(&self, redirect: &str, challenge: &str, state: &str, nonce: &str) -> String {
        let query: Vec<String> = [("client_id", self.client_id.as_str()), ("redirect_uri", redirect), ("response_type", "code"), ("scope", "openid email"), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state), ("nonce", nonce)]
            .iter()
            .map(|(k, v)| format!("{k}={}", encode(v)))
            .collect();
        format!("{}?{}", self.authorization_endpoint, query.join("&"))
    }

    fn exchange(&self, code: &str, verifier: &str, redirect: &str) -> Result<String, Unavailable> {
        let mut form = vec![("code", code), ("client_id", &self.client_id), ("code_verifier", verifier), ("redirect_uri", redirect), ("grant_type", "authorization_code")];
        if let Some(secret) = &self.client_secret {
            form.push(("client_secret", secret));
        }
        let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(30))).max_redirects(0).http_status_as_error(false).build().into();
        let mut response = agent.post(&self.token_endpoint).send_form(form).map_err(|_| REFUSED)?;
        if response.status() != 200 {
            return Err(REFUSED);
        }
        let body = response.body_mut().with_config().limit(MAX_TOKEN_RESPONSE).read_to_vec().map_err(|_| REFUSED)?;
        let answer: serde_json::Value = serde_json::from_slice(&body).map_err(|_| REFUSED)?;
        answer["id_token"].as_str().filter(|t| !t.is_empty()).map(str::to_string).ok_or(REFUSED)
    }

    /// Opens the browser through `open` and blocks until an ID token carrying `nonce`, or failure.
    /// Run it off the UI thread. Errors name the step's owner only: no code, state or token.
    // ponytail: no cancel button; a closed browser tab holds the sign-in buttons for up to `wait`,
    // as long as the plan's deadline. A cancel flag in `SignIn` if that annoys anyone.
    pub fn sign_in(&self, nonce: &str, open: &dyn Fn(&str) -> Result<(), Unavailable>) -> Result<String, Unavailable> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|_| REFUSED)?;
        let redirect = format!("http://127.0.0.1:{}", listener.local_addr().map_err(|_| REFUSED)?.port());
        let (verifier, state) = (random_url_safe(32), random_url_safe(16));
        open(&self.authorization_url(&redirect, &challenge(&verifier), &state, nonce))?;
        let code = wait_for_code(&listener, &state, Instant::now() + self.wait)?;
        drop(listener);
        self.exchange(&code, &verifier, &redirect)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn query_of(url: &str, name: &str) -> Option<String> {
        url.split_once('?')?.1.split('&').find_map(|p| p.strip_prefix(name)?.strip_prefix('=')).and_then(decode)
    }

    fn send(port: u16, request: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.write_all(request.as_bytes()).unwrap();
        let mut out = String::new();
        let _ = s.read_to_string(&mut out);
        out
    }

    fn port_of(url: &str) -> u16 {
        query_of(url, "redirect_uri").unwrap().rsplit(':').next().unwrap().parse().unwrap()
    }

    /// A token endpoint that answers every POST with `status` and `body`, and keeps what it got.
    fn token_server(status: &'static str, body: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let url = format!("http://127.0.0.1:{}/token", listener.local_addr().unwrap().port());
        let seen: Arc<Mutex<Vec<String>>> = Arc::default();
        let log = seen.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let mut request = vec![];
                let mut chunk = [0; 4096];
                loop {
                    let n = stream.read(&mut chunk).unwrap();
                    request.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&request).to_string();
                    let Some((head, rest)) = text.split_once("\r\n\r\n") else { continue };
                    let length: usize = head.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length: ").map(|v| v.trim().parse().unwrap())).unwrap_or(0);
                    if rest.len() >= length {
                        log.lock().unwrap().push(rest.to_string());
                        break;
                    }
                }
                write!(stream, "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        (url, seen)
    }

    fn client(token_endpoint: &str) -> GoogleClient {
        GoogleClient { token_endpoint: token_endpoint.into(), authorization_endpoint: "https://auth.invalid/o".into(), wait: Duration::from_secs(20), ..GoogleClient::new("client id", None) }
    }

    #[test]
    fn pkce_matches_rfc_7636() {
        assert_eq!(challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        assert_eq!(random_url_safe(32).len(), 43, "RFC 7636's verifier length");
        assert_ne!(random_url_safe(16), random_url_safe(16));
    }

    #[test]
    fn callback_parsing() {
        let get = |q: &str| format!("GET {q} HTTP/1.1\r\nHost: x\r\n\r\n");
        let parse = |q: &str| callback(get(q).as_bytes(), "s1");
        assert_eq!(parse("/?state=s1&code=4%2F0Ab"), Callback::Code("4/0Ab".into()), "codes contain an encoded slash");
        assert_eq!(parse("/?code=c&state=s1&scope=email"), Callback::Code("c".into()));
        assert_eq!(parse("/?state=wrong&code=c"), Callback::Ignored);
        assert_eq!(parse("/?code=c"), Callback::Ignored, "no state");
        assert_eq!(parse("/?state=wrong&error=access_denied"), Callback::Ignored, "a forged error doesn't end the wait");
        assert_eq!(parse("/?state=s1&error=access_denied"), Callback::Denied);
        assert_eq!(parse("/?state=s1&code=c&error=x"), Callback::Denied);
        assert_eq!(parse("/?state=s1"), Callback::Denied);
        assert_eq!(parse("/favicon.ico"), Callback::Ignored);
        assert_eq!(parse("/other?state=s1&code=c"), Callback::Ignored);
        assert_eq!(callback(b"POST /?state=s1&code=c HTTP/1.1\r\n\r\n", "s1"), Callback::Ignored);
        assert_eq!(callback(&[0xff, 0xfe], "s1"), Callback::Ignored);
        assert_eq!(parse("/?state=s1&code=%zz"), Callback::Denied, "a code that doesn't decode isn't a code");
    }

    #[test]
    fn signs_in_through_loopback_and_binds_only_there() {
        let (endpoint, seen) = token_server("200 OK", r#"{"id_token":"a.b.c","access_token":"x"}"#);
        let urls: Arc<Mutex<Vec<String>>> = Arc::default();
        let log = urls.clone();
        let token = client(&endpoint)
            .sign_in("the+nonce", &move |url| {
                log.lock().unwrap().push(url.to_string());
                let (port, state) = (port_of(url), query_of(url, "state").unwrap());
                std::thread::spawn(move || {
                    assert!(send(port, "GET /favicon.ico HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 400"));
                    assert!(send(port, "GET /?state=forged&code=stolen HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 400"), "a bad state is refused, and the wait goes on");
                    assert!(send(port, &format!("GET /?state={state}&code=4%2Freal HTTP/1.1\r\n\r\n")).starts_with("HTTP/1.1 200"));
                    assert!(TcpStream::connect(("127.0.0.1", port)).is_err(), "closed after the valid request");
                });
                Ok(())
            })
            .unwrap();
        assert_eq!(token, "a.b.c");
        let url = urls.lock().unwrap()[0].clone();
        assert!(url.starts_with("https://auth.invalid/o?"));
        assert_eq!(query_of(&url, "client_id").unwrap(), "client id");
        assert_eq!(query_of(&url, "nonce").unwrap(), "the+nonce");
        assert_eq!(query_of(&url, "code_challenge_method").unwrap(), "S256");
        assert_eq!(query_of(&url, "scope").unwrap(), "openid email");
        assert!(query_of(&url, "redirect_uri").unwrap().starts_with("http://127.0.0.1:"), "only the loopback address");
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1, "only the valid callback is exchanged");
        let form: Vec<(&str, String)> = seen[0].split('&').map(|p| p.split_once('=').unwrap()).map(|(k, v)| (k, decode(v).unwrap())).collect();
        let field = |name: &str| form.iter().find(|(k, _)| *k == name).map(|(_, v)| v.clone());
        assert_eq!(field("code").unwrap(), "4/real");
        assert_eq!(field("grant_type").unwrap(), "authorization_code");
        assert_eq!(challenge(&field("code_verifier").unwrap()), query_of(&url, "code_challenge").unwrap(), "the verifier answers the challenge sent");
        assert_eq!(field("redirect_uri"), query_of(&url, "redirect_uri"));
        assert_eq!(field("client_secret"), None);
    }

    #[test]
    fn sends_the_build_time_secret_when_there_is_one() {
        let (endpoint, seen) = token_server("200 OK", r#"{"id_token":"t"}"#);
        let google = GoogleClient { client_secret: Some("not secret".into()), ..client(&endpoint) };
        assert_eq!(google.exchange("c", "v", "http://127.0.0.1:1"), Ok("t".into()));
        assert!(seen.lock().unwrap()[0].contains("client_secret=not"));
    }

    #[test]
    fn token_endpoint_refusals() {
        for (status, body) in [("400 Bad Request", r#"{"id_token":"t"}"#), ("200 OK", r#"{"access_token":"t"}"#), ("200 OK", r#"{"id_token":""}"#), ("200 OK", "<html>")] {
            let (endpoint, _) = token_server(status, body);
            assert_eq!(client(&endpoint).exchange("c", "v", "r"), Err(REFUSED), "{status} {body}");
        }
    }

    #[test]
    fn denied_and_a_browser_that_will_not_open_exchange_nothing() {
        let (endpoint, seen) = token_server("200 OK", r#"{"id_token":"t"}"#);
        let denied = client(&endpoint).sign_in("n", &|url| {
            let (port, state) = (port_of(url), query_of(url, "state").unwrap());
            std::thread::spawn(move || send(port, &format!("GET /?state={state}&error=access_denied HTTP/1.1\r\n\r\n")));
            Ok(())
        });
        assert_eq!(denied, Err(REFUSED));
        assert_eq!(client(&endpoint).sign_in("n", &|_| Err(Unavailable("opening a link"))), Err(Unavailable("opening a link")));
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn the_deadline_ends_a_wait_and_stalling_or_flooding_clients_dont_block_the_real_one() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        assert_eq!(wait_for_code(&listener, "s", Instant::now() + Duration::from_millis(120)), Err(REFUSED));

        let port = listener.local_addr().unwrap().port();
        let waiter = std::thread::spawn(move || wait_for_code(&listener, "s", Instant::now() + Duration::from_secs(20)));
        let flood = format!("GET /?{} HTTP/1.1\r\n\r\n", "x".repeat(MAX_REQUEST));
        assert!(send(port, &flood).starts_with("HTTP/1.1 400"), "over the 8 KB cap");
        let _silent = TcpStream::connect(("127.0.0.1", port)).unwrap();
        let started = Instant::now();
        send(port, "GET /?state=s&code=ok HTTP/1.1\r\n\r\n");
        assert_eq!(waiter.join().unwrap(), Ok("ok".into()));
        assert!(started.elapsed() < Duration::from_secs(5), "a silent connection costs at most its own limit");
    }
}

/// Spec US2's independent test: fake authorization server, real flowd with a test JWKS.
#[cfg(all(test, unix))]
mod flowd_tests {
    use super::*;
    use crate::remote::MemorySecrets;
    use crate::remote::channel::WebSockets;
    use crate::remote::enrollment::*;
    use crate::remote::{DeviceKeys, Secrets};
    use crate::settings::test_flowd::Flowd;
    use std::sync::{Arc, Mutex};

    struct GoKeys(Arc<Flowd>, Mutex<Option<(String, Vec<u8>)>>);
    impl DeviceKeys for GoKeys {
        fn create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
            let (scalar, public) = self.0.keygen();
            *self.1.lock().unwrap() = Some((scalar, public.clone()));
            Ok((vec![1], public))
        }
        fn public_key(&self, _: &[u8]) -> Option<Vec<u8>> {
            self.1.lock().unwrap().as_ref().map(|k| k.1.clone())
        }
        fn sign(&self, message: &[u8], _: &[u8]) -> Result<Vec<u8>, Unavailable> {
            Ok(self.0.sign(&self.1.lock().unwrap().as_ref().unwrap().0, message))
        }
        fn delete(&self, _: &[u8]) -> Result<(), Unavailable> {
            Ok(())
        }
    }

    /// The browser and Google: approves on the loopback address, then answers the exchange with an
    /// ID token for the nonce it was given, signed by the test issuer flowd trusts.
    struct FakeGoogle(Arc<Flowd>, Option<&'static str>);
    impl SignIn for FakeGoogle {
        fn sign_in(&self, provider: IdentityProvider, nonce: &str) -> Result<String, Unavailable> {
            assert_eq!(provider, IdentityProvider::Google);
            let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            let endpoint = format!("http://127.0.0.1:{}/token", listener.local_addr().unwrap().port());
            let token = self.0.mint_id_token(self.1.unwrap_or(nonce));
            std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0; 4096];
                let _ = stream.read(&mut request).unwrap();
                let body = format!("{{\"id_token\":\"{token}\"}}");
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
                // Closing with the request's body unread resets the connection under the client's read.
                stream.shutdown(std::net::Shutdown::Write).unwrap();
                let _ = std::io::copy(&mut stream, &mut std::io::sink());
            });
            let google = GoogleClient { token_endpoint: endpoint, wait: Duration::from_secs(30), ..GoogleClient::new(Flowd::GOOGLE_CLIENT_ID, None) };
            google.sign_in(nonce, &|url| {
                let query = url.split_once('?').unwrap().1;
                let field = |name: &str| query.split('&').find_map(|p| p.strip_prefix(name)?.strip_prefix('=')).and_then(decode).unwrap();
                let (redirect, state) = (field("redirect_uri"), field("state"));
                let port: u16 = redirect.rsplit(':').next().unwrap().parse().unwrap();
                std::thread::spawn(move || {
                    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
                    write!(s, "GET /?state={state}&code=c HTTP/1.1\r\n\r\n").unwrap();
                });
                Ok(())
            })
        }
    }

    fn enroll(flowd: &Arc<Flowd>, forged: Option<&'static str>) -> (Enrollment, Arc<MemorySecrets>, Result<String, EnrollError>) {
        let secrets = Arc::new(MemorySecrets::default());
        let e = Enrollment::new(Parts {
            secrets: secrets.clone(),
            keys: Arc::new(GoKeys(flowd.clone(), Mutex::default())),
            sign_in: Arc::new(FakeGoogle(flowd.clone(), forged)),
            identity: Arc::new(HttpIdentity),
            transports: Arc::new(WebSockets::default()),
            now: Box::new(system_now),
            device_name: "Conformance PC".into(),
        });
        e.load(RemoteSettings { origin: Some(flowd.remote.clone()), state: "off".into(), notice: None });
        let identity = e.fetch_server_identity().unwrap();
        e.pin(&identity).unwrap();
        let result = e.enroll(IdentityProvider::Google);
        (e, secrets, result)
    }

    #[test]
    fn enrolls_with_the_channel_bound_nonce_and_refuses_another() {
        let flowd = Arc::new(Flowd::start_with_test_issuer());
        let (e, secrets, result) = enroll(&flowd, None);
        assert_eq!(result.as_deref(), Ok("pending"), "a new Google account waits for approval");
        assert_eq!(e.settings().state, "pending");
        assert!(secrets.read("device-key").unwrap().is_some());

        let (_, secrets, result) = enroll(&flowd, Some("a-nonce-from-another-channel"));
        assert!(matches!(result, Err(EnrollError::Channel(_))), "{result:?}");
        assert_eq!(secrets.read("device-key").unwrap(), None);
    }
}
