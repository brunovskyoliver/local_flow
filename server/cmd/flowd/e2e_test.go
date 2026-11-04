package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"localflow/server/internal/remote"
)

// TestE2EServe is the server half of scripts/test-pairing-e2e.sh, skipped unless
// LOCALFLOW_E2E_INFO names a file. It runs flowd's own serve path in this test
// binary on loopback, with a temp data dir and the fake Keychain that a built flowd
// can't use (keychainRunner has no production override, on purpose). It writes the
// origin and a fresh token to that file and serves until <file>.done appears.
func TestE2EServe(t *testing.T) {
	info := os.Getenv("LOCALFLOW_E2E_INFO")
	if info == "" {
		t.Skip("LOCALFLOW_E2E_INFO not set")
	}
	dir := initDataDir(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	remote := freePort(t)
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"serve", "--listen=" + freePort(t), "--remote-listen=" + remote, "--data-dir=" + dir,
			"--backend=http://127.0.0.1:9/v1", "--model=none"}, none, io.Discard)
	}()
	origin := "http://" + remote
	for ready := false; !ready; {
		select {
		case err := <-done:
			t.Fatal("flowd stopped:", err)
		case <-time.After(20 * time.Millisecond):
		}
		if response, err := http.Get(origin + "/v1/remote/identity"); err == nil {
			response.Body.Close()
			ready = true
		}
	}
	created, err := admin("--data-dir", dir, "token", "create", "--label", "E2E", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var token struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(bytes.NewReader([]byte(created))).Decode(&token); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]string{"origin": origin, "token": token.Token})
	if err := os.WriteFile(info+".tmp", data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(info+".tmp", info); err != nil {
		t.Fatal(err)
	}
	for {
		select {
		case err := <-done:
			t.Fatal("flowd stopped:", err)
		case <-ctx.Done():
			t.Fatal("the Swift side never finished")
		case <-time.After(100 * time.Millisecond):
		}
		if _, err := os.Stat(info + ".done"); err == nil {
			cancel()
			<-done
			return
		}
	}
}

// e2eClient is a minimal device: one channel to the in-process listener.
type e2eClient struct {
	t       *testing.T
	ws      *websocket.Conn
	channel *remote.Channel
}

// e2eHello dials the remote listener and sends a hello for purpose, returning
// the client and the server's first message.
func e2eHello(t *testing.T, origin string, serverKey []byte, purpose remote.Purpose, access string) (*e2eClient, remote.Message) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(origin, "http")+"/v1/remote/channel", nil)
	if err != nil {
		t.Fatal(err)
	}
	ws.SetReadLimit(remote.MaxBinaryMessage)
	t.Cleanup(func() { ws.CloseNow() })
	replyKey, err := hpke.DHKEM(ecdh.X25519()).GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	channel, err := remote.NewClient(serverKey, replyKey)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"schema_version": 1, "type": "hello", "purpose": purpose,
		"reply_key": base64.RawURLEncoding.EncodeToString(replyKey.PublicKey().Bytes())}
	if access != "" {
		body["access_token"] = access
	}
	plaintext, _ := json.Marshal(body)
	sealed, err := channel.Hello(plaintext)
	if err != nil {
		t.Fatal(err)
	}
	if err := ws.Write(ctx, websocket.MessageBinary, sealed); err != nil {
		t.Fatal(err)
	}
	c := &e2eClient{t: t, ws: ws, channel: channel}
	return c, c.recv()
}

func (c *e2eClient) send(m remote.Message) {
	c.t.Helper()
	data, err := remote.EncodeMessage(m)
	if err != nil {
		c.t.Fatal(err)
	}
	sealed, err := c.channel.Seal(remote.Frame{Kind: remote.KindControl, Payload: data})
	if err != nil {
		c.t.Fatal(err)
	}
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, sealed); err != nil {
		c.t.Fatal(err)
	}
}

func (c *e2eClient) recv() remote.Message {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		c.t.Fatal(err)
	}
	frame, err := c.channel.Open(data)
	if err != nil {
		c.t.Fatal(err)
	}
	message, err := remote.DecodeMessage(frame.Payload)
	if err != nil {
		c.t.Fatal(err)
	}
	return message
}

// signParts is a DER ECDSA P-256 signature over SHA-256 of the parts.
func signParts(t *testing.T, key *ecdsa.PrivateKey, parts ...[]byte) []byte {
	t.Helper()
	digest := sha256.Sum256(bytes.Join(parts, nil))
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signature
}

// within polls check every 20 ms until it is true or d has passed.
func within(t *testing.T, d time.Duration, what string, check func() bool) time.Duration {
	t.Helper()
	start := time.Now()
	for !check() {
		if time.Since(start) > d {
			t.Fatalf("%s not within %v", what, d)
		}
		time.Sleep(20 * time.Millisecond)
	}
	return time.Since(start)
}

// SC-004 and SC-005 against flowd's own serve path: a device paired through the
// in-process remote listener with a token for a named user shows under that
// user with its kind in list --json, and as connected in the admin status's
// channels, within 5 s. After revoke device its channel closes and its count
// leaves channels within 2 s.
func TestE2EUsersAndChannels(t *testing.T) {
	dir := initDataDir(t)
	remoteAddr, adminAddr := freePort(t), freePort(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"serve", "--listen=" + freePort(t), "--remote-listen=" + remoteAddr, "--admin-listen=" + adminAddr,
			"--data-dir=" + dir, "--backend=http://127.0.0.1:9/v1", "--model=none"}, none, io.Discard)
	}()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	origin := "http://" + remoteAddr
	var identity remote.Identity
	within(t, 5*time.Second, "identity", func() bool {
		response, err := http.Get(origin + "/v1/remote/identity")
		if err != nil {
			return false
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		identity, err = remote.DecodeIdentity(body)
		return err == nil
	})
	if !slices.Contains(identity.Features, remote.FeatureDeviceKind) {
		t.Fatalf("identity features %v", identity.Features)
	}
	var adminToken string
	within(t, 5*time.Second, "admin token", func() bool {
		data, err := os.ReadFile(filepath.Join(dir, adminTokenFile))
		adminToken = strings.TrimSpace(string(data))
		return err == nil && adminToken != ""
	})
	status := func() *channelsStatus {
		request, _ := http.NewRequest("GET", "http://"+adminAddr+"/v1/admin/status", nil)
		request.Header.Set("Authorization", "Bearer "+adminToken)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			return nil
		}
		defer response.Body.Close()
		var body struct {
			Channels *channelsStatus `json:"channels"`
		}
		if json.NewDecoder(response.Body).Decode(&body) != nil {
			return nil
		}
		return body.Channels
	}
	within(t, 5*time.Second, "admin status", func() bool { return status() != nil })

	// A named user, then a token for that user.
	created, err := admin("--data-dir", dir, "user", "create", "--name", "Ana", "--json")
	if err != nil {
		t.Fatal(created, err)
	}
	var user struct{ ID int64 }
	if err := json.Unmarshal([]byte(created), &user); err != nil || user.ID == 0 {
		t.Fatal(created, err)
	}
	issued, err := admin("--data-dir", dir, "token", "create", "--label", "Ana's iPhone", "--user", strconv.FormatInt(user.ID, 10), "--json")
	if err != nil {
		t.Fatal(err)
	}
	var token struct{ Token string }
	if err := json.Unmarshal([]byte(issued), &token); err != nil {
		t.Fatal(err)
	}

	// The device pairs with a kind, refreshes and opens a session.
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public, _ := key.PublicKey.Bytes()
	c, ready := e2eHello(t, origin, identity.ServerKey, remote.PurposeEnroll, "")
	if ready.MessageType() != "ready" {
		t.Fatalf("%#v", ready)
	}
	c.send(remote.Pair{Op: 1, PairingToken: token.Token, DeviceName: "Ana's iPhone", DeviceKind: "iphone", DeviceKey: public,
		Signature: signParts(t, key, []byte(remote.PairSignatureLabel), c.channel.Binding())})
	paired, ok := c.recv().(remote.Enrolled)
	if !ok || paired.State != "approved" || paired.RefreshToken == "" {
		t.Fatalf("%#v", paired)
	}
	c, ready = e2eHello(t, origin, identity.ServerKey, remote.PurposeRefresh, "")
	if ready.MessageType() != "ready" {
		t.Fatalf("%#v", ready)
	}
	digest := sha256.Sum256([]byte(paired.RefreshToken))
	c.send(remote.Refresh{Op: 1, RefreshToken: paired.RefreshToken,
		Signature: signParts(t, key, []byte(remote.RefreshSignatureLabel), c.channel.Binding(), digest[:])})
	tokens, ok := c.recv().(remote.Tokens)
	if !ok || tokens.AccessToken == "" {
		t.Fatalf("%#v", tokens)
	}
	session, ready := e2eHello(t, origin, identity.ServerKey, remote.PurposeSession, tokens.AccessToken)
	if ready.MessageType() != "ready" {
		t.Fatalf("%#v", ready)
	}
	closed := make(chan struct{})
	go func() { // reads keep answering pings until the server closes the channel
		defer close(closed)
		for {
			if _, _, err := session.ws.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	connected := time.Now()

	// SC-004: the user, its device and kind, and the live channel, within 5 s.
	var deviceID int64
	within(t, 5*time.Second, "device in list --json", func() bool {
		out, err := admin("--data-dir", dir, "list", "--json")
		var list adminListJSON
		if err != nil || json.Unmarshal([]byte(out), &list) != nil {
			return false
		}
		for _, u := range list.Users {
			for _, d := range u.Devices {
				if d.Name == "Ana's iPhone" && u.ID == user.ID && d.Kind != nil && *d.Kind == "iphone" && d.State == "approved" {
					deviceID = d.ID
					return true
				}
			}
		}
		return false
	})
	within(t, 5*time.Second-time.Since(connected), "device in channels", func() bool {
		s := status()
		return s != nil && slices.Contains(s.Devices, remote.DeviceChannels{DeviceID: deviceID, Channels: 1}) && s.Open >= 1
	})
	t.Logf("SC-004: listed and connected %v after the session opened", time.Since(connected))

	// SC-005: revoke closes the channel and drops the count within 2 s.
	if out, err := admin("--data-dir", dir, "revoke", "device", strconv.FormatInt(deviceID, 10)); err != nil {
		t.Fatal(out, err)
	}
	revoked := time.Now()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("the revoked device's channel stayed open")
	}
	within(t, 2*time.Second-time.Since(revoked), "count drop", func() bool {
		s := status()
		return s != nil && !slices.ContainsFunc(s.Devices, func(d remote.DeviceChannels) bool { return d.DeviceID == deviceID })
	})
	t.Logf("SC-005: closed and dropped %v after revoke", time.Since(revoked))
}
