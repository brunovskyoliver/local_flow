# Hardware restart acceptance

Status: pending (T091, SC-007). Follow [Restart safety](../quickstart.md) in the signed production app: force-quit once during live recognition and once during finalization. Preserve database dumps of rows before the saved progress point, compare after launch resume, and record recovery-outcome rows plus source-file integrity. Deterministic reconciler/finalizer tests establish selected code paths only; no hardware force-quit result is claimed here.
