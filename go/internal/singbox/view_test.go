package singbox

import (
	"testing"
	"time"
)

// Start держит s.mu до 150 с; страница и канал (Status/Ready/Effective) не должны на нём виснуть.
func TestStatusDoesNotWaitForStart(t *testing.T) {
	ready := make(chan struct{})
	s := &box{ready: ready, vReady: ready}
	s.mu.Lock()
	defer s.mu.Unlock()
	done := make(chan struct{})
	go func() {
		_ = s.Status()
		_ = s.Ready()
		_ = s.Effective()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Status/Ready/Effective ждут s.mu, занятый Start")
	}
}
