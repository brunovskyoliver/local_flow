package analysis

import (
	"testing"

	"localflow/server/internal/backend"
)

// The default output cap is what every analysis request hands the backend; the
// adapter refused it (65 KiB ceiling against a 96 KiB line cap) and every summary
// failed with backend_error before a request was sent.
func TestDefaultOutputBytesFitTheBackendCeiling(t *testing.T) {
	if DefaultLimits().OutputBytes > backend.MaxOutputBytes {
		t.Fatalf("OutputBytes %d exceeds backend.MaxOutputBytes %d", DefaultLimits().OutputBytes, backend.MaxOutputBytes)
	}
}
