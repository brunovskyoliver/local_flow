package usage

import (
	"encoding/json"
	"os"
	"strings"
)

// LoadExporter reads optional owner configuration and a separate private key
// file; neither credential nor URL is logged. Empty config disables export.
func LoadExporter(s *Store, path string) (*Exporter, error) {
	if path == "" {
		return nil, nil
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 4096 {
		return nil, ErrInvalid
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c struct {
		Endpoint       string `json:"endpoint"`
		AllowedHost    string `json:"allowed_host"`
		Installation   string `json:"installation"`
		CredentialFile string `json:"credential_file"`
	}
	if err = json.Unmarshal(data, &c); err != nil {
		return nil, ErrInvalid
	}
	info, err = os.Stat(c.CredentialFile)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 512 {
		return nil, ErrInvalid
	}
	key, err := os.ReadFile(c.CredentialFile)
	if err != nil {
		return nil, err
	}
	return NewExporter(s, ExportConfig{Endpoint: c.Endpoint, AllowedHost: c.AllowedHost, Installation: c.Installation, Credential: strings.TrimSpace(string(key))})
}
