package update

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

func TestDialUsesFallbackResolverWhenSystemFails(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		if c, e := ln.Accept(); e == nil {
			c.Close()
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	var steps []string
	ctx := WithProgress(context.Background(), func(_, text string) { steps = append(steps, text) })
	sys := func(context.Context, string) ([]string, error) { return nil, errors.New("slow") }
	fb := func(context.Context, string) ([]string, error) { return []string{"127.0.0.1"}, nil }
	c, err := newDialContext(time.Second, time.Second, sys, fb)(ctx, "tcp", net.JoinHostPort("example.invalid", port))
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
	if len(steps) != 1 || steps[0] != "системный DNS медленный, использую запасной" {
		t.Fatalf("steps: %v", steps)
	}
}

func TestDialSystemTimeoutThenFallback(t *testing.T) {
	sys := func(ctx context.Context, _ string) ([]string, error) { <-ctx.Done(); return nil, ctx.Err() }
	fb := func(context.Context, string) ([]string, error) { return nil, errors.New("fb down") }
	_, err := newDialContext(time.Second, 50*time.Millisecond, sys, fb)(context.Background(), "tcp", "example.invalid:443")
	if err == nil || err.Error() != "fb down" {
		t.Fatalf("err: %v", err)
	}
}
