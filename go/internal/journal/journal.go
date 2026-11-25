package journal

import (
	"errors"
	"io"

	"remoteagents/internal/api"
)

type Options struct {
	MaxBytes int64
	Keep     int
}

type Journal struct{ noopLogger }

var _ api.Logger = (*Journal)(nil)

func New(p api.Paths, stream string, o Options) (*Journal, error) {
	return nil, errors.New("journal: not-implemented")
}
func (j *Journal) Tail(n int) []string   { return nil }
func (j *Journal) Zip(w io.Writer) error { return errors.New("journal: not-implemented") }
func (j *Journal) Close() error          { return errors.New("journal: not-implemented") }

// Boot returns a minimal no-op logger; replaced by the first New call.
func Boot(home string) api.Logger { return &noopLogger{} }

type noopLogger struct{}

func (l *noopLogger) Info(event string, kv ...any)                {}
func (l *noopLogger) Warn(event string, kv ...any)                {}
func (l *noopLogger) Error(event string, kv ...any)               {}
func (l *noopLogger) With(component string) api.Logger            { return l }
func (l *noopLogger) Secret(value string)                         {}
func (l *noopLogger) Writer(stream, source string) io.WriteCloser { return discardWriteCloser{} }

type discardWriteCloser struct{}

func (discardWriteCloser) Write(p []byte) (int, error) { return len(p), nil }
func (discardWriteCloser) Close() error                { return nil }
func (l *noopLogger) Drops() int64                     { return 0 }
