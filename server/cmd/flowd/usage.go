package main

import (
	"context"
	"localflow/server/internal/usage"
	"log"
	"path/filepath"
)

// Reporting initialization is optional. Its files/configuration must never
// prevent approved users from using the inference server.
func openOptionalUsage(ctx context.Context, dir, config string, approved func(usage.Identity) bool, logger *log.Logger) (*usage.Store, *usage.Exporter) {
	store, err := usage.Open(filepath.Join(dir, "usage.sqlite"), usage.Config{Approved: approved})
	if err != nil {
		logger.Print("usage event=store_unavailable")
		return nil, nil
	}
	if err = store.Reconcile(ctx); err != nil {
		store.Close()
		logger.Print("usage event=store_unavailable")
		return nil, nil
	}
	exporter, err := usage.LoadExporter(store, config)
	if err != nil {
		logger.Print("usage event=export_configuration_invalid")
		return store, nil
	}
	return store, exporter
}
