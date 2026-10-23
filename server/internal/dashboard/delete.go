package dashboard

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"html/template"
	"localflow/server/internal/usage"
	"net/http"
)

var deletePage = template.Must(template.New("delete").Parse(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Delete shared usage</title><body style="font:18px/1.5 system-ui;max-width:640px;margin:60px auto;padding:24px"><h1>Delete this user's shared usage?</h1><p>This removes their retained usage reports and disables sharing grants for their devices. Dictation history and account access stay unchanged. Removal remains pending until the source server acknowledges it.</p><form method="post" action="/delete"><input type="hidden" name="csrf" value="{{.CSRF}}"><input type="hidden" name="user" value="{{.User}}"><button type="submit" style="font:inherit;padding:12px">Delete shared usage</button> <a href="/">Cancel</a></form></body></html>`))

func (h *Handler) deleteUsage(w http.ResponseWriter, r *http.Request, s session) {
	if r.Method == http.MethodGet {
		user := r.URL.Query().Get("user")
		if len(user) != 36 {
			http.Error(w, "Invalid user", 400)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = deletePage.Execute(w, struct{ CSRF, User string }{s.csrf, user})
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", 405)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if r.ParseForm() != nil || subtle.ConstantTimeCompare([]byte(r.FormValue("csrf")), []byte(s.csrf)) != 1 {
		http.Error(w, "Forbidden", 403)
		return
	}
	if err := h.projection.RequestDeletion(r.Context(), h.cfg.Installation, r.FormValue("user")); err != nil {
		http.Error(w, "Deletion unavailable", 400)
		return
	}
	http.Redirect(w, r, "/", 303)
}
func (p *Projection) RequestDeletion(ctx context.Context, installation, user string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	var count int
	if err := p.db.QueryRowContext(ctx, "SELECT count(*) FROM controls WHERE installation=? AND user=?", installation, user).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return usage.ErrInvalid
	}
	_, err := p.db.ExecContext(ctx, "INSERT OR IGNORE INTO deletion_requests(installation,user) VALUES(?,?)", installation, user)
	return err
}
func (h *Handler) deletionRequests(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", 405)
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+h.cfg.IngestCredential)) != 1 || r.Header.Get("X-LocalFlow-Installation") != h.cfg.Installation {
		http.Error(w, "Unauthorized", 401)
		return
	}
	h.projection.mu.Lock()
	defer h.projection.mu.Unlock()
	rows, err := h.projection.db.QueryContext(r.Context(), "SELECT user FROM deletion_requests WHERE installation=? ORDER BY user LIMIT 100", h.cfg.Installation)
	if err != nil {
		http.Error(w, "Unavailable", 503)
		return
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var user string
		if rows.Scan(&user) != nil {
			http.Error(w, "Unavailable", 503)
			return
		}
		out = append(out, user)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Users []string `json:"users"`
	}{out})
}
