//go:build linux

package platform

import (
	"runtime"

	"remoteagents/internal/api"
)

// Current returns the platform implementation for Linux.
func Current() api.Platform { return &stubPlatform{} }

func (p *stubPlatform) OS() string   { return runtime.GOOS }
func (p *stubPlatform) Arch() string { return runtime.GOARCH }
