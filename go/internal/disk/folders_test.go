package disk

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const dSrvID = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"

type fakeST struct {
	mu      sync.Mutex
	folders []map[string]any
	pending map[string]string // id → label
	posted  []map[string]any
	paths   []string
}

func (f *fakeST) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.Header.Get("X-API-Key") != "k" {
			w.WriteHeader(403)
			return
		}
		f.paths = append(f.paths, r.Method+" "+r.URL.RequestURI())
		switch {
		case r.URL.Path == "/rest/system/status":
			w.Write([]byte(`{"myID":"ME"}`))
		case r.URL.Path == "/rest/config/folders" && r.Method == "GET":
			json.NewEncoder(w).Encode(f.folders)
		case r.URL.Path == "/rest/config/folders" && r.Method == "POST":
			var m map[string]any
			json.NewDecoder(r.Body).Decode(&m)
			f.posted = append(f.posted, m)
			f.folders = append(f.folders, m)
		case r.URL.Path == "/rest/config/defaults/folder":
			w.Write([]byte(`{"id":"","paused":false}`))
		case r.URL.Path == "/rest/cluster/pending/folders":
			out := map[string]any{}
			for id, l := range f.pending {
				out[id] = map[string]any{"offeredBy": map[string]any{dSrvID: map[string]any{"label": l}}}
			}
			json.NewEncoder(w).Encode(out)
		default:
			w.Write([]byte(`{}`))
		}
	})
}

func TestAcceptFoldersAndFinish(t *testing.T) {
	st := &fakeST{pending: map[string]string{"abc-123": "docs"}}
	ts := httptest.NewServer(st.handler(t))
	defer ts.Close()
	home, base := t.TempDir(), t.TempDir()
	busy := filepath.Join(base, "busy")
	os.MkdirAll(busy, 0o755)
	os.WriteFile(filepath.Join(busy, "x.txt"), []byte("x"), 0o644)
	env := FoldersEnv{Home: home, Client: NewClientURL(ts.URL, "k"), ServerID: dSrvID, Base: base,
		Folders:   []Folder{{ID: "docs"}, {ID: "busy"}, {ID: "later"}},
		OfferWait: time.Millisecond, Sleep: func(context.Context, time.Duration) error { return nil }}
	st.pending["busy"] = "busy"
	res, err := Finish(context.Background(), env)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Accepted) != 1 || res.Accepted[0] != "docs" || res.Skipped["busy"] != "папка не пуста" || len(res.Waiting) != 1 {
		t.Fatalf("%+v", res)
	}
	p := st.posted[0]
	if p["id"] != "abc-123" || p["label"] != "docs" || p["path"] != filepath.Join(base, "docs") || p["type"] != "sendreceive" {
		t.Fatalf("%v", p)
	}
	if b, _ := os.ReadFile(filepath.Join(base, "docs", ".stignore")); !strings.Contains(string(b), "#include") {
		t.Fatal("нет .stignore")
	}
	if !NeedFinish(home) {
		t.Fatal("ждём предложения: стадия должна остаться folders")
	}
	// сервер предложил последнюю — стадия done, принятая не дублируется
	st.mu.Lock()
	st.pending["later"] = "later"
	st.mu.Unlock()
	if res, err = Finish(context.Background(), env); err != nil || len(res.Waiting) != 0 || len(st.posted) != 2 {
		t.Fatalf("%+v %v", res, err)
	}
	if NeedFinish(home) {
		t.Fatal("ожидали done")
	}
}

func TestSkipsLinksAndPlaceholder(t *testing.T) {
	base := t.TempDir()
	real := t.TempDir()
	if err := os.Symlink(real, filepath.Join(base, "lnk")); err == nil {
		if checkTarget(filepath.Join(base, "lnk")) == "" {
			t.Fatal("ссылка допустима")
		}
	}
	ph := filepath.Join(base, "ph")
	os.MkdirAll(ph, 0o755)
	os.WriteFile(filepath.Join(ph, "desktop.ini"), []byte("[RemoteAgents]\r\nOwner=RemoteAgents.Disk.v2\r\nPlaceholder=1\r\n"), 0o644)
	if w := checkTarget(ph); w != "" {
		t.Fatal(w)
	}
	os.WriteFile(filepath.Join(ph, "desktop.ini"), []byte("[x]\r\n"), 0o644)
	if checkTarget(ph) == "" {
		t.Fatal("чужой desktop.ini не заглушка")
	}
}

func TestClientMethods(t *testing.T) {
	st := &fakeST{}
	ts := httptest.NewServer(st.handler(t))
	defer ts.Close()
	c := NewClientURL(ts.URL, "k")
	ctx := context.Background()
	for _, f := range []func() error{
		func() error { return c.Pause(ctx, "a b") }, func() error { return c.Resume(ctx, "a") },
		func() error { return c.Override(ctx, "a") }, func() error { return c.Revert(ctx, "a") },
		func() error { return c.Scan(ctx, "a", "sub/x") },
	} {
		if err := f(); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{"PATCH /rest/config/folders/a%20b", "PATCH /rest/config/folders/a", "POST /rest/db/override?folder=a",
		"POST /rest/db/revert?folder=a", "POST /rest/db/scan?folder=a&sub=sub%2Fx"}
	if strings.Join(st.paths, "|") != strings.Join(want, "|") {
		t.Fatalf("%v", st.paths)
	}
	if err := NewClientURL(ts.URL, "bad").Scan(ctx, "a", ""); err == nil || strings.Contains(err.Error(), "bad") {
		t.Fatalf("%v", err)
	}
}
