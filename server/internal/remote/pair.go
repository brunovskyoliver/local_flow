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
// signature touches no token. The store writes the audit row of a redemption
// and of its refusals, so only a bad signature or late message is audited here.
func (a *accountOps) pair(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message := m.(Pair)
	code, device, user := CodeInternal, int64(0), int64(0)
	defer func() {
		a.cfg.Logger.Printf("remote channel=%d op=pair user=%d device=%d code=%s", c.ID(), user, device, code)
	}()
	if c.Now().Sub(c.ReadyAt()) > EnrollIdleTimeout ||
		!verifyDeviceSignature(message.DeviceKey, message.Signature, []byte(PairSignatureLabel), c.Binding()) {
		code = CodeUnauthorized
		a.audit(ctx, c, accounts.AuditEntry{Actor: accounts.SystemActor, Action: "pair", Outcome: string(code)})
		return nil, coded(code, "pair signature or lateness")
	}
	pairing, err := a.cfg.Store.RedeemPairingToken(ctx, message.PairingToken, message.DeviceName, message.DeviceKey)
	if err != nil {
		code = pairCode(err)
		return nil, coded(code, "pair refused")
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
