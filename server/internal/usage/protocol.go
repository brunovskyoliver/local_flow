// Package usage owns optional, content-free product accounting. Authenticated
// callers supply identity separately; wire requests cannot select another user.
package usage

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"regexp"
	"time"
)

const MaxBody = 65536
const MaxRows = 180000
const MaxDevices = 1000
const MaxUsers = 100
const RetentionDays = 90

var ErrInvalid = errors.New("usage: invalid")
var ErrBusy = errors.New("usage: busy")
var ErrRevoked = errors.New("usage: revoked")
var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type Row struct {
	Day           string `json:"day"`
	Revision      uint64 `json:"revision"`
	LocalCount    int64  `json:"local_count"`
	RemoteCount   int64  `json:"remote_count"`
	LocalAudioMS  int64  `json:"local_audio_ms"`
	RemoteAudioMS int64  `json:"remote_audio_ms"`
	Coverage      string `json:"coverage"`
}
type Request struct {
	Version int    `json:"version"`
	Action  string `json:"action"`
	Epoch   uint64 `json:"epoch,omitempty"`
	Grant   string `json:"grant,omitempty"`
	Rows    []Row  `json:"rows,omitempty"`
}
type Ack struct {
	Day      string `json:"day"`
	Revision uint64 `json:"revision"`
	Status   string `json:"status"`
}
type Response struct {
	Version            int    `json:"version"`
	Status             string `json:"status"`
	UserID             string `json:"user_id"`
	DeviceID           string `json:"device_id"`
	Epoch              uint64 `json:"epoch"`
	Grant              string `json:"grant,omitempty"`
	Enabled            bool   `json:"enabled"`
	ControlRevision    uint64 `json:"control_revision"`
	DeletionCutoff     uint64 `json:"deletion_cutoff"`
	PropagationPending bool   `json:"propagation_pending"`
	Rows               []Ack  `json:"rows"`
}

func Decode(data []byte) (Request, error) {
	var r Request
	if len(data) > MaxBody || uniqueJSON(data) != nil {
		return r, ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil {
		return r, ErrInvalid
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return r, ErrInvalid
	}
	// Require every row field, including zero-valued counters.
	var raw struct {
		Rows []map[string]json.RawMessage `json:"rows"`
	}
	_ = json.Unmarshal(data, &raw)
	for _, row := range raw.Rows {
		for _, key := range []string{"day", "revision", "local_count", "remote_count", "local_audio_ms", "remote_audio_ms", "coverage"} {
			v, ok := row[key]
			if !ok || bytes.Equal(v, []byte("null")) {
				return r, ErrInvalid
			}
		}
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(data, &fields)
	if r.Action == "status" || r.Action == "enable" {
		for _, key := range []string{"epoch", "grant", "rows"} {
			if _, ok := fields[key]; ok {
				return r, ErrInvalid
			}
		}
	}
	if r.Action != "snapshot" {
		if _, ok := fields["rows"]; ok {
			return r, ErrInvalid
		}
	}
	if err := r.Validate(); err != nil {
		return r, err
	}
	return r, nil
}
func (r Request) Validate() error {
	if r.Version != 1 || r.Epoch > math.MaxInt64 {
		return ErrInvalid
	}
	switch r.Action {
	case "status", "enable":
		if r.Epoch != 0 || r.Grant != "" || r.Rows != nil {
			return ErrInvalid
		}
	case "withdraw", "delete_device", "delete_user":
		if r.Epoch == 0 || !uuidPattern.MatchString(r.Grant) || r.Rows != nil {
			return ErrInvalid
		}
	case "snapshot":
		if r.Epoch == 0 || !uuidPattern.MatchString(r.Grant) || len(r.Rows) < 1 || len(r.Rows) > 100 {
			return ErrInvalid
		}
		seen := map[string]bool{}
		for _, row := range r.Rows {
			if row.Valid() != nil || seen[row.Day] {
				return ErrInvalid
			}
			seen[row.Day] = true
		}
	default:
		return ErrInvalid
	}
	return nil
}
func (r Row) Valid() error {
	if _, err := time.Parse("2006-01-02", r.Day); err != nil {
		return ErrInvalid
	}
	if r.Revision == 0 || r.Revision > math.MaxInt64 || r.LocalCount < 0 || r.RemoteCount < 0 || r.LocalAudioMS < 0 || r.RemoteAudioMS < 0 || (r.Coverage != "complete" && r.Coverage != "partial") {
		return ErrInvalid
	}
	if r.LocalCount > math.MaxInt64-r.RemoteCount || r.LocalAudioMS > math.MaxInt64-r.RemoteAudioMS {
		return ErrInvalid
	}
	return nil
}
