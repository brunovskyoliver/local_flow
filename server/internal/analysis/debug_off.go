//go:build !localflow_debug

package analysis

// DebugBuild reports whether this binary was built with -tags localflow_debug.
// Request dumping is compiled out of normal builds entirely.
const DebugBuild = false
