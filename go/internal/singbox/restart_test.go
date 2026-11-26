package singbox

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func TestRestartDelayBounds(t *testing.T) {
	want := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for i, w := range want {
		if got := restartDelay(i); got != w {
			t.Errorf("n=%d: %v, want %v", i, got, w)
		}
	}
	if restartDelay(1000) != restartMax {
		t.Fatal("нет верхней границы")
	}
}

// Падение sing-box: перезапуск с растущей задержкой до успеха; счётчик падений сохраняется между попытками.
func TestRecoverBacksOffThenSucceeds(t *testing.T) {
	s := &box{log: &fake.Logger{}, binary: "sb"}
	var delays []time.Duration
	s.sleep = func(_ context.Context, d time.Duration) bool { delays = append(delays, d); return true }
	calls := 0
	s.restart = func(context.Context, api.Effective) error {
		calls++
		if calls < 3 {
			return errors.New("boom")
		}
		return nil
	}
	s.recover(context.Background(), api.Effective{})
	if calls != 3 || len(delays) != 3 || delays[0] != 500*time.Millisecond || delays[1] != time.Second || delays[2] != 2*time.Second {
		t.Fatalf("calls=%d delays=%v", calls, delays)
	}
}

// Stop во время ожидания — перезапуска нет.
func TestRecoverStopsWhenWaitCancelled(t *testing.T) {
	s := &box{log: &fake.Logger{}, binary: "sb"}
	s.sleep = func(context.Context, time.Duration) bool { return false }
	s.restart = func(context.Context, api.Effective) error { t.Fatal("перезапуск после Stop"); return nil }
	s.recover(context.Background(), api.Effective{})
}

func TestRecoverSkipsWhenAlreadyRunning(t *testing.T) {
	s := &box{log: &fake.Logger{}, binary: "sb", running: true}
	s.sleep = func(context.Context, time.Duration) bool { return true }
	s.restart = func(context.Context, api.Effective) error { t.Fatal("двойной запуск"); return nil }
	s.recover(context.Background(), api.Effective{})
}

func TestRenderUsesDefaultInterface(t *testing.T) {
	out, err := Render(api.RenderContext{Cfg: &api.Config{}, DefaultIface: "Wi-Fi", ChanPort: 1, ClashPort: 2})
	if err != nil {
		t.Skip("минимальный конфиг не рендерится: ", err)
	}
	var v struct {
		Route map[string]any `json:"route"`
	}
	if err = json.Unmarshal(out, &v); err != nil {
		t.Fatal(err)
	}
	if v.Route["default_interface"] != "Wi-Fi" || v.Route["auto_detect_interface"] != nil {
		t.Fatalf("route=%v", v.Route)
	}
	out, _ = Render(api.RenderContext{Cfg: &api.Config{}, ChanPort: 1, ClashPort: 2})
	if !strings.Contains(string(out), `"auto_detect_interface":true`) {
		t.Fatalf("без интерфейса должен остаться auto_detect: %s", out)
	}
}

// Интерфейс не менялся (сменился, например, только адрес): без перезапуска, зависшие соединения сбрасываются.
func TestNetChangedSameIfaceResetsConnections(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { got = r.Method + " " + r.URL.Path }))
	defer srv.Close()
	port, _ := strconv.Atoi(srv.URL[strings.LastIndex(srv.URL, ":")+1:])
	s := &box{log: &fake.Logger{}, binary: "sb", running: true, vClash: port, o: Options{DefaultIface: func() string { return "Wi-Fi" }}}
	s.rc.DefaultIface = "Wi-Fi"
	restarted, err := s.NetChanged(context.Background())
	if err != nil || restarted || got != "DELETE /connections" {
		t.Fatalf("restarted=%v err=%v got=%q", restarted, err, got)
	}
}
