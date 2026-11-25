//go:build linux

package platform

import "errors"

// OpenBrowser — заглушка до P5b.
func (p *stubPlatform) OpenBrowser(url, runAs string) error {
	return errors.New("platform: not-implemented")
}
