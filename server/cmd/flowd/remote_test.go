package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"localflow/server/internal/accounts"
)

type stepClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *stepClock) Now() time.Time  { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *stepClock) Set(t time.Time) { c.mu.Lock(); c.now = t; c.mu.Unlock() }

// The accounts loop sweeps invites past their deadline on its first tick and
// then at most once a minute by the store clock, and the same tick's poll sees
// the deleted pending device.
func TestWatchAccountsSweepsInvites(t *testing.T) {
	ctx := context.Background()
	start := time.UnixMilli(1_790_000_000_000)
	clock := &stepClock{now: start}
	store, err := accounts.Open(filepath.Join(t.TempDir(), "data"), clock.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	user, err := store.CreateUser(ctx, "Owner", accounts.AdminActor("oliver"))
	if err != nil {
		t.Fatal(err)
	}
	key := func(n byte) []byte { k := bytes.Repeat([]byte{n}, 65); k[0] = 0x04; return k }
	mac, err := store.AddDevice(ctx, user.ID, "Mac", key(1), "")
	if err != nil || store.SetDeviceState(ctx, mac.ID, accounts.DeviceApproved, accounts.AdminActor("oliver")) != nil {
		t.Fatal(err)
	}
	pending := func(n byte) int64 {
		t.Helper()
		value, _, err := store.CreateInvite(ctx, make([]byte, 32), mac.ID)
		if err != nil {
			t.Fatal(err)
		}
		pairing, err := store.Redeem(ctx, value, "Phone", key(n), "", bytes.Repeat([]byte{n}, 32))
		if err != nil {
			t.Fatal(err)
		}
		return pairing.DeviceID
	}
	exists := func(id int64) bool {
		_, err := store.Device(ctx, id)
		if err != nil && !errors.Is(err, accounts.ErrNotFound) {
			t.Fatal(err)
		}
		return err == nil
	}
	watcher, err := store.Watch(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer watcher.Close()
	ticks := make(chan time.Time)
	loopCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		watchAccounts(loopCtx, watcher, store, ticks, clock.Now, log.New(io.Discard, "", 0))
	}()
	defer func() { cancel(); <-done }()
	// at sets the clock and ticks; a second tick at the same time (never a
	// sweep) returns only once the first has been handled.
	at := func(d time.Duration) {
		clock.Set(start.Add(d))
		ticks <- time.Time{}
		ticks <- time.Time{}
	}

	first := pending(2) // confirm by start+10m
	at(0)               // the first tick sweeps
	at(10*time.Minute + 10*time.Second)
	if exists(first) || watcher.Snapshot().Approved(user.ID, first) {
		t.Fatal("not swept after its deadline")
	}
	clock.Set(start.Add(15 * time.Minute))
	second := pending(3)                // confirm by start+25m
	at(24*time.Minute + 50*time.Second) // sweeps, nothing due
	at(25*time.Minute + 10*time.Second) // due, but 20 s after the last sweep
	if !exists(second) {
		t.Fatal("swept twice within a minute")
	}
	at(25*time.Minute + 50*time.Second)
	if exists(second) {
		t.Fatal("not swept a minute after the last sweep")
	}
}
