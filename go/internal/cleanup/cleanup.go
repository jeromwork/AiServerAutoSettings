package cleanup

import (
	"errors"

	"remoteagents/internal/api"
)

type Cleaner struct{}

func New(p api.Paths, log api.Logger, plat api.Platform) (*Cleaner, error) {
	return nil, errors.New("cleanup: not-implemented")
}
