package install

import (
	"errors"

	"remoteagents/internal/api"
)

func Install(p api.Paths, plat api.Platform, log api.Logger, start bool) error {
	return errors.New("install: not-implemented")
}
func Enable(p api.Paths, plat api.Platform, log api.Logger) error {
	return errors.New("install: not-implemented")
}
func Uninstall(p api.Paths, plat api.Platform, log api.Logger, purge bool) error {
	return errors.New("install: not-implemented")
}
