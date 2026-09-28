//go:build localflow_debug

package main

import "flag"

const remoteDebugBuild = true

func registerRemoteDebugFlags(fs *flag.FlagSet, r *remoteConfig) {
	fs.StringVar(&r.testIssuer, "test-issuer", "", "debug builds only: accept ID tokens from this local issuer")
	fs.StringVar(&r.testJWKS, "test-jwks", "", "debug builds only: JWKS file for --test-issuer")
	fs.BoolVar(&r.debugBusy, "debug-busy", false, "debug builds only: answer every dictation_start with busy")
}
