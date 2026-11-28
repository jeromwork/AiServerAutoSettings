package update

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"remoteagents/internal/api"
)

func TestCheckTimesOutOnSilentServer(t *testing.T) {
	stop := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) { <-stop }))
	defer srv.Close()
	defer close(stop)
	r := newRelease(t)
	u, err := New(api.NewPaths(t.TempDir()), nil, Options{Repo: "o/r", Signers: []string{r.signers}, BaseURL: srv.URL, HeaderTimeout: 200 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_, err = u.Check(context.Background())
	if err == nil || !strings.Contains(err.Error(), "нет ответа") {
		t.Fatalf("want readable timeout, got %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("too slow")
	}
}

func TestCheckHonoursOverallDeadline(t *testing.T) {
	stop := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) { <-stop }))
	defer srv.Close()
	defer close(stop)
	r := newRelease(t)
	u, _ := New(api.NewPaths(t.TempDir()), nil, Options{Repo: "o/r", Signers: []string{r.signers}, BaseURL: srv.URL, HeaderTimeout: time.Minute, CheckTimeout: 200 * time.Millisecond})
	start := time.Now()
	if _, err := u.Check(context.Background()); err == nil || time.Since(start) > 5*time.Second {
		t.Fatalf("deadline not applied: %v", err)
	}
}

func TestProgressStepsOnFetch(t *testing.T) {
	r := newRelease(t)
	u, _ := r.updater(t, t.TempDir())
	var mu sync.Mutex
	var steps []string
	ctx := WithProgress(context.Background(), func(stage, text string) {
		mu.Lock()
		steps = append(steps, stage+": "+text)
		mu.Unlock()
	})
	rel, err := u.Check(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := u.Fetch(ctx, *rel); err != nil {
		t.Fatal(err)
	}
	all := strings.Join(steps, "\n")
	for _, want := range []string{"описание выпуска", "контрольные суммы", "Проверяю подпись", "downloading: Скачано", "контрольная сумма совпала"} {
		if !strings.Contains(all, want) {
			t.Errorf("missing step %q in:\n%s", want, all)
		}
	}
}
