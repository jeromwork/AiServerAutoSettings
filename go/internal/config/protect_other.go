//go:build !windows

package config

import "remoteagents/internal/api"

func protect(path string, log api.Logger) {}
