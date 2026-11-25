package api

import (
	"context"
	"io"
)

const VersionRe = `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`

type Release struct {
	Version string
	Build   int
	OS      string
	Arch    string
	URL     string
	SHA256  string
}

type Updater interface {
	Check(ctx context.Context) (*Release, error)
	Fetch(ctx context.Context, r Release) (candidate string, err error)
	Stage(ctx context.Context, candidate, version string) error
	ReceiveDev(ctx context.Context, body io.Reader, sha256, version string) (candidate string, err error)
}
