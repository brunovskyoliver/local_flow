package remote

import (
	"context"
	"errors"

	"localflow/server/internal/accounts"
)

// PairSignatureLabel prefixes what the device key signs in a pair message.
const PairSignatureLabel = "localflow-v1-pair"

// pair redeems a one-time token (specs/027-remote-pairing/contracts/pairing.md).
// The device key's signature over the channel binding comes first; a refused
// signature touches no token. Every refusal closes the channel, so the hello
// limit bounds redemption attempts. Only the store audits, and only tokens it
// knows: anyone can reach this code, and rows from strangers would push the
// admin history out of the capped audit log. The log line records the rest.
func (a *accountOps) pair(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message := m.(Pair)
	code, device, user := CodeInternal, int64(0), int64(0)
	defer func() {
		a.cfg.Logger.Printf("remote channel=%d op=pair user=%d device=%d kind=%s code=%s", c.ID(), user, device, message.DeviceKind.LogValue(), code)
	}()
	if c.Now().Sub(c.ReadyAt()) > EnrollIdleTimeout ||
		!verifyDeviceSignature(message.DeviceKey, message.Signature, []byte(PairSignatureLabel), c.Binding()) {
		code = CodeUnauthorized
		c.Fail(message.Op, code)
		return nil, nil
	}
	pairing, err := a.cfg.Store.RedeemPairingToken(ctx, message.PairingToken, message.DeviceName, message.DeviceKey, accounts.DeviceKind(message.DeviceKind))
	if err != nil {
		code = pairCode(err)
		c.Fail(message.Op, code)
		return nil, nil
	}
	code, device, user = "ok", pairing.DeviceID, pairing.UserID
	a.reload(ctx)
	return nil, c.Send(ctx, Enrolled{Op: message.Op, State: "approved", RefreshToken: pairing.Refresh})
}

func pairCode(err error) ErrorCode {
	switch {
	case errors.Is(err, accounts.ErrPairingTokenInvalid):
		return CodePairingTokenInvalid
	case errors.Is(err, accounts.ErrUnauthorized):
		return CodeUnauthorized
	case errors.Is(err, accounts.ErrRevoked):
		return CodeRevoked
	case errors.Is(err, accounts.ErrNotApproved):
		return CodeNotApproved
	}
	return CodeInternal
}
