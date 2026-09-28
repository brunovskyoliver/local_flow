//go:build localflow_acceptance

package remote

import (
	"runtime"
	"testing"
)

// SC-007 acceptance run: 50 of 50 revocations (alternating device and user)
// close every affected channel within one second, with the real 250 ms poll
// on loopback. The result is recorded in
// specs/014-remote-dictation-server/acceptance/revocation.md.
func TestRevocationAcceptance50(t *testing.T) {
	const trials = 50
	latencies := runRevocationTrials(t, trials)
	within := 0
	for _, latency := range latencies {
		if latency <= RevocationBound {
			within++
		}
	}
	median, maximum := latencySummary(latencies)
	t.Logf("revocation acceptance: trials=%d within_bound=%d median=%v max=%v go=%s",
		trials, within, median, maximum, runtime.Version())
	t.Logf("latencies: %v", latencies)
	if within != trials {
		t.Fatalf("%d of %d trials within %v", within, trials, RevocationBound)
	}
}
