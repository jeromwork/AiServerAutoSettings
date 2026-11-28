package disk

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBackoff(t *testing.T) {
	want := []time.Duration{30 * time.Second, 60 * time.Second, 120 * time.Second, 240 * time.Second, 300 * time.Second, 300 * time.Second}
	for i, w := range want {
		if g := backoff(i + 1); g != w {
			t.Fatalf("backoff(%d)=%v want %v", i+1, g, w)
		}
	}
}

func TestSafeLine(t *testing.T) {
	if _, ok := safeLine("INFO: started"); ok {
		t.Fatal("INFO должен отбрасываться")
	}
	s, ok := safeLine(`WARN: failed "C:\Users\x\secret.txt" /home/a/b`)
	if !ok || s != "WARN: failed <..> <..>" {
		t.Fatalf("got %q %v", s, ok)
	}
}

func TestNeedJoinAndPort(t *testing.T) {
	h := t.TempDir()
	if !needJoin(h) {
		t.Fatal("пустой home требует join")
	}
	os.WriteFile(filepath.Join(h, "join.json"), []byte(`{"stage":"server"}`), 0600)
	if !needJoin(h) {
		t.Fatal("stage server требует join")
	}
	os.WriteFile(filepath.Join(h, "join.json"), []byte(`{"stage":"done"}`), 0600)
	if needJoin(h) {
		t.Fatal("done не требует join")
	}
	os.WriteFile(filepath.Join(h, "server.json"), []byte(`{"deviceId":"X","listen":22005}`), 0600)
	if p := serverSyncPort(nil, h); p != 22005 {
		t.Fatalf("server.json port %d", p)
	}
	ch := json.RawMessage(`{"inbounds":[{"tag":"ssh","override_port":1},{"tag":"sync","override_port":22010}]}`)
	if p := serverSyncPort(ch, h); p != 22010 {
		t.Fatalf("channel port %d", p)
	}
}
