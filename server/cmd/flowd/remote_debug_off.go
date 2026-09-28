//go:build !localflow_debug

package main

import "flag"

// remoteDebugBuild reports whether this binary was built with -tags
// localflow_debug. Normal builds do not even register --test-issuer,
// --test-jwks and --debug-busy, so they are unknown flags there.
const remoteDebugBuild = false

func registerRemoteDebugFlags(*flag.FlagSet, *remoteConfig) {}
