// Package platform contains the OS hooks used by the v2 core.
package platform

import (
	"remoteagents/internal/api"
	"runtime"
)

type nativePlatform struct{}

func Current() api.Platform         { return nativePlatform{} }
func (nativePlatform) OS() string   { return runtime.GOOS }
func (nativePlatform) Arch() string { return runtime.GOARCH }

var _ api.Platform = nativePlatform{}
