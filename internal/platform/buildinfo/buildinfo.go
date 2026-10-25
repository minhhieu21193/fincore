// Package buildinfo holds values stamped into the binary at build time via -ldflags.
package buildinfo

// Set with: -ldflags "-X github.com/minhhieu21193/fincore/internal/platform/buildinfo.Version=..."
var (
	Version = "dev"
	Commit  = "unknown"
	// FaultRate is the share (0..1) of payment requests that fail with HTTP 500.
	// It is only ever non-zero in the deliberately bad build used for the canary
	// rollback demo; it cannot be changed at runtime.
	FaultRate = "0"
)
