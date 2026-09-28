package remote

import (
	"context"
	"crypto/sha256"
	"errors"

	"localflow/server/internal/accounts"
)

// refresh redeems a refresh token signed by the device key over
// "localflow-v1-refresh" ‖ binding ‖ SHA-256(refresh_token). Success rotates
// the refresh token and issues a 15-minute access token; not_approved leaves
// the token valid and unrotated; the replaced token revokes the device.
func (a *accountOps) refresh(ctx context.Context, c *Conn, m Message) (Operation, error) {
	message := m.(Refresh)
	binding := c.Binding()
	tokenHash := sha256.Sum256([]byte(message.RefreshToken))
	var device, user int64
	signed := false
	tokens, err := a.cfg.Store.Refresh(ctx, message.RefreshToken, func(d accounts.Device) error {
		device, user = d.ID, d.UserID
		if !verifyDeviceSignature(d.PublicKey, message.Signature, []byte(RefreshSignatureLabel), binding, tokenHash[:]) {
			return accounts.ErrUnauthorized
		}
		signed = true
		return nil
	})
	code := refreshCode(err)
	a.cfg.Logger.Printf("remote channel=%d op=refresh user=%d device=%d code=%s", c.ID(), user, device, orOK(code))
	switch {
	case err == nil:
		a.reload(ctx)
		_, _ = a.cfg.Store.TouchDevice(ctx, tokens.DeviceID)
		return nil, c.Send(ctx, Tokens{Op: message.Op, AccessToken: tokens.Access,
			ExpiresIn: int(accounts.AccessLifetime.Seconds()), RefreshToken: tokens.Refresh})
	case errors.Is(err, accounts.ErrRefreshReuse):
		// The store revoked the device and audited refresh_reuse; closing its
		// channels now rather than at the next poll.
		a.reload(ctx)
	case device != 0 && (code == CodeRevoked || (code == CodeUnauthorized && !signed)):
		// A known token with a bad signature, or a revoked account: audited
		// against the device. Routine outcomes (ok, not_approved) are not,
		// so refreshes every 12 minutes do not crowd the audit cap.
		a.audit(ctx, c, accounts.AuditEntry{Actor: accounts.SystemActor, Action: "refresh",
			Target: accounts.DeviceTarget(device), Outcome: string(code)})
	}
	return nil, coded(code, "refresh refused")
}

func refreshCode(err error) ErrorCode {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, accounts.ErrUnauthorized):
		return CodeUnauthorized
	case errors.Is(err, accounts.ErrNotApproved):
		return CodeNotApproved
	case errors.Is(err, accounts.ErrRevoked), errors.Is(err, accounts.ErrRefreshReuse):
		return CodeRevoked
	}
	return CodeInternal
}

func orOK(code ErrorCode) ErrorCode {
	if code == "" {
		return "ok"
	}
	return code
}
