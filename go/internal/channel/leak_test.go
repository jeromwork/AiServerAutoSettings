package channel

import (
	"context"
	"testing"
	"time"

	"remoteagents/internal/api/fake"
)

func TestRegistryCount(t *testing.T) {
	c := &chn{log: &fake.Logger{}, sbEvent: make(chan struct{}, 1), handover: make(chan struct{}, 1)}
	k := &conn{stop: func() {}}
	k.cl = nil
	c.register(k)
	if c.Sessions() != 1 {
		t.Fatal("want 1")
	}
	c.unregister(k)
	if c.Sessions() != 0 {
		t.Fatal("want 0")
	}
}

func TestSbWatcherHandover(t *testing.T) {
	c := &chn{log: &fake.Logger{}, sbEvent: make(chan struct{}, 1), handover: make(chan struct{}, 1)}
	c.st.State = "up"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go c.sbWatcher(ctx.Done(), func() bool { return false })
	c.SingboxEvent("outbound-error")
	select {
	case <-c.handover:
	case <-time.After(time.Second):
		t.Fatal("no handover")
	}
}
