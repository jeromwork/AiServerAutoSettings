package journal

import (
	"io"

	"remoteagents/internal/api"
)

type Options struct {
	MaxBytes int64
	Keep     int
}

type Journal struct{}

func New(p api.Paths, stream string, o Options) (*Journal, error) { panic("not implemented") }
func (j *Journal) Tail(n int) []string                            { panic("not implemented") }
func (j *Journal) Zip(w io.Writer) error                          { panic("not implemented") }
func (j *Journal) Close() error                                   { panic("not implemented") }
func Boot(home string) api.Logger                                 { panic("not implemented") }
