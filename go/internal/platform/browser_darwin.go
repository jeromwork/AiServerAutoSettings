//go:build darwin

package platform

import "errors"

// OpenBrowser — заглушка до P5b.
func (p *stubPlatform) OpenBrowser(url, runAs string) error {
	return errors.New("platform: not-implemented")
}
