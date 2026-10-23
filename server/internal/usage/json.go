package usage

import (
	"bytes"
	"encoding/json"
	"io"
)

// uniqueJSON rejects duplicate object keys and deeply nested payloads before
// decoding typed structures. JSON null is not an alternative to required fields.
func uniqueJSON(data []byte) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 16 {
			return ErrInvalid
		}
		tok, e := d.Token()
		if e != nil {
			return ErrInvalid
		}
		delim, ok := tok.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			keys := map[string]bool{}
			for d.More() {
				k, e := d.Token()
				s, ok := k.(string)
				if e != nil || !ok || keys[s] {
					return ErrInvalid
				}
				keys[s] = true
				if e = value(depth + 1); e != nil {
					return e
				}
			}
			end, e := d.Token()
			if e != nil || end != json.Delim('}') {
				return ErrInvalid
			}
		case '[':
			for d.More() {
				if e = value(depth + 1); e != nil {
					return e
				}
			}
			end, e := d.Token()
			if e != nil || end != json.Delim(']') {
				return ErrInvalid
			}
		default:
			return ErrInvalid
		}
		return nil
	}
	if err := value(0); err != nil {
		return err
	}
	if _, e := d.Token(); e != io.EOF {
		return ErrInvalid
	}
	return nil
}
func requiredRows(data []byte) error {
	var raw struct {
		Rows []map[string]json.RawMessage `json:"rows"`
	}
	if json.Unmarshal(data, &raw) != nil {
		return ErrInvalid
	}
	for _, row := range raw.Rows {
		for _, key := range []string{"day", "revision", "local_count", "remote_count", "local_audio_ms", "remote_audio_ms", "coverage"} {
			v, ok := row[key]
			if !ok || bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
				return ErrInvalid
			}
		}
	}
	return nil
}
func DecodeBatch(data []byte) (Batch, error) {
	var b Batch
	if len(data) > MaxBody || uniqueJSON(data) != nil || requiredRows(data) != nil {
		return b, ErrInvalid
	}
	if requiredObject(data, "installation", "control", "rows") != nil {
		return b, ErrInvalid
	}
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(data, &raw)
	if requiredObject(raw["control"], "user_id", "device_id", "epoch", "enabled", "revision", "deletion_cutoff") != nil {
		return b, ErrInvalid
	}
	if dir, ok := raw["directory"]; ok && requiredObject(dir, "label", "revision", "removed") != nil {
		return b, ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(&b) != nil {
		return b, ErrInvalid
	}
	return b, b.Validate()
}

func requiredObject(data []byte, keys ...string) error {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		return ErrInvalid
	}
	for _, key := range keys {
		v, ok := fields[key]
		if !ok || bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			return ErrInvalid
		}
	}
	return nil
}
