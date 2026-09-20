// flowd serves optional text rewriting and meeting analysis. Inference runs in
// a separate process; flowd owns no model weights.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"localflow/server/internal/analysis"
	"localflow/server/internal/backend"
	"localflow/server/internal/rewrite"
)

type configuration struct {
	listen   string
	backend  backend.Config
	shield   bool
	versions []int
	token    string
	analysis analysis.Limits
	dumpDir  string
}

func parse(args []string, getenv func(string) string, output io.Writer) (configuration, error) {
	var c configuration
	c.analysis = analysis.DefaultLimits()
	fs := flag.NewFlagSet("flowd serve", flag.ContinueOnError)
	fs.SetOutput(output)
	fs.StringVar(&c.listen, "listen", "127.0.0.1:8080", "HTTP listen address")
	fs.StringVar(&c.backend.BaseURL, "backend", "http://127.0.0.1:8000/v1", "OpenAI-compatible API base URL, including /v1")
	fs.StringVar(&c.backend.Model, "model", "mtplx-qwen35-9b-optimized-speed", "served model id")
	shield := fs.String("shield", "on", "entity shielding: on or off")
	versions := fs.String("protocol-versions", "1", "comma-separated advertised protocol versions (acceptance double)")
	fs.DurationVar(&c.backend.DebugDelay, "debug-delay", 0, "delay inference for acceptance tests")
	fs.DurationVar(&c.backend.FirstTokenTimeout, "first-token-timeout", 5*time.Second, "backend first-token deadline")
	fs.DurationVar(&c.backend.Timeout, "backend-timeout", 20*time.Second, "total backend deadline")
	fs.BoolVar(&c.analysis.Enabled, "analysis", true, "serve the meeting analysis endpoints")
	fs.IntVar(&c.analysis.Concurrency, "analysis-concurrency", 1, "analysis admission slots")
	fs.IntVar(&c.analysis.InputBytes, "analysis-input-bytes", 98304, "max summed segment/notes/partials text bytes per request")
	fs.IntVar(&c.analysis.OutputTokensChunk, "analysis-output-tokens-chunk", 2048, "backend max_tokens for chunk requests")
	fs.IntVar(&c.analysis.OutputTokensFull, "analysis-output-tokens", 3072, "backend max_tokens for full and synthesis requests")
	fs.IntVar(&c.analysis.ContextTokens, "analysis-context-tokens", 32768, "usable backend context tokens")
	fs.DurationVar(&c.analysis.Timeout, "analysis-timeout", 120*time.Second, "backend deadline per analysis request")
	fs.DurationVar(&c.analysis.FirstTokenTimeout, "analysis-first-token-timeout", 15*time.Second, "backend first-token deadline for analysis")
	fs.DurationVar(&c.analysis.QueueWait, "analysis-queue-wait", 30*time.Second, "rewrite-first gate window")
	fs.BoolVar(&c.analysis.Preempt, "analysis-preempt", true, "cancel an in-flight analysis call when a rewrite arrives")
	fs.StringVar(&c.dumpDir, "analysis-dump-requests", "", "debug builds only: write each analysis request body to this directory")
	if err := fs.Parse(args); err != nil {
		return c, err
	}
	if fs.NArg() != 0 {
		return c, errors.New("unexpected positional arguments")
	}
	if *shield != "on" && *shield != "off" {
		return c, errors.New("shield must be on or off")
	}
	c.shield = *shield == "on"
	for _, v := range strings.Split(*versions, ",") {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || len(c.versions) >= 8 {
			return c, errors.New("invalid protocol versions")
		}
		c.versions = append(c.versions, n)
	}
	if c.backend.FirstTokenTimeout <= 0 || c.backend.Timeout <= 0 || c.backend.Timeout > 5*time.Minute || c.backend.FirstTokenTimeout > 5*time.Minute || c.backend.DebugDelay < 0 || c.backend.DebugDelay > 5*time.Minute {
		return c, errors.New("timeouts must be positive and at most five minutes; debug delay may be zero")
	}
	if c.dumpDir != "" && !analysis.DebugBuild {
		return c, errors.New("--analysis-dump-requests requires a build with -tags localflow_debug")
	}
	c.token = getenv("LOCALFLOW_REWRITE_TOKEN")
	c.backend.Token = getenv("LOCALFLOW_BACKEND_TOKEN")
	for _, token := range []string{c.token, c.backend.Token} {
		if len(token) > 4096 || strings.ContainsAny(token, "\r\n") {
			return c, errors.New("invalid credential")
		}
	}
	host, _, err := net.SplitHostPort(c.listen)
	if err != nil {
		return c, errors.New("listen must be host:port")
	}
	ip := net.ParseIP(host)
	loopback := ip != nil && ip.IsLoopback()
	// Literal addresses avoid DNS rebinding between validation and listen.
	if host != "" && ip == nil {
		return c, errors.New("listen host must be an IP literal")
	}
	if !loopback && c.token == "" {
		return c, errors.New("LOCALFLOW_REWRITE_TOKEN is required for a non-loopback listener")
	}
	return c, nil
}
func run(ctx context.Context, args []string, getenv func(string) string, output io.Writer) error {
	if len(args) == 0 {
		fmt.Fprintf(output, "LocalFlow flowd %s\nUsage: flowd serve [flags]  (alias: flowd rewrite)\n", rewrite.ServerVersion)
		return nil
	}
	if args[0] != "serve" && args[0] != "rewrite" {
		return errors.New("unknown subcommand; use flowd serve")
	}
	c, err := parse(args[1:], getenv, output)
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	if err != nil {
		return err
	}
	adapter, err := backend.New(c.backend)
	if err != nil {
		return err
	}
	defer adapter.Close()
	logger := log.New(output, "flowd ", log.LstdFlags)
	gate := analysis.NewGate(c.analysis.QueueWait, c.analysis.Preempt)
	rewriteHandler := rewrite.NewHandler(rewrite.HandlerConfig{Backend: adapter, Token: c.token, Shield: c.shield, ProtocolVersions: c.versions, Logger: logger, Gate: gate})
	mux := http.NewServeMux()
	mux.Handle("/v1/rewrite", rewriteHandler)
	mux.Handle("/v1/rewrite/health", rewriteHandler)
	if c.analysis.Enabled {
		analysisHandler := analysis.NewHandler(analysis.HandlerConfig{
			Backend: adapter, Token: c.token, ProtocolVersions: c.versions,
			Limits: c.analysis, Gate: gate, Logger: logger, DumpDir: c.dumpDir,
		})
		mux.Handle("/v1/analysis/meeting", analysisHandler)
		mux.Handle("/v1/analysis/health", analysisHandler)
	}
	server := &http.Server{Addr: c.listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: c.analysis.Timeout + 10*time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384, BaseContext: func(net.Listener) context.Context { return ctx }}
	listener, err := net.Listen("tcp", c.listen)
	if err != nil {
		return errors.New("could not open listener")
	}
	finished := make(chan error, 1)
	go func() { finished <- server.Serve(listener) }()
	logger.Printf("version=%s listening=%s", rewrite.ServerVersion, listener.Addr())
	select {
	case err := <-finished:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
		}
		<-finished
		return nil
	}
}
func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "flowd:", err)
		os.Exit(1)
	}
}
