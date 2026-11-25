//go:build linux

package platform

import (
	"errors"
	"strings"
)

func (p *stubPlatform) OpenBrowser(url, runAs string) error {
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return errors.New("platform: browser-url: expected HTTP(S) URL")
	}
	return errors.New("platform: browser-unavailable: tracked process launch requires Procs and Traces integration")
}
