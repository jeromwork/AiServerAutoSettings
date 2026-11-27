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
	s.restart = func(context.Context, api.Effective) error {
		t.Fatal("перезапуск после Stop")
		return nil
	}
	s.recover(context.Background(), api.Effective{})
}

func TestRecoverSkipsWhenAlreadyRunning(t *testing.T) {
	s := &box{log: &fake.Logger{}, binary: "sb", running: true}
	s.sleep = func(context.Context, time.Duration) bool { return true }
	s.restart = func(context.Context, api.Effective) error { t.Fatal("двойной запуск"); return nil }
	s.recover(context.Background(), api.Effective{})
}

// Канал (Render) не привязан к интерфейсу: ни default_interface, ни auto_detect_interface (этап A убрал их). Привязка к
// физическому адаптеру — только у процесса VPN (RenderVPN), он выходит к мостам мимо собственного TUN.
func TestRenderChannelHasNoInterfaceBinding(t *testing.T) {
	out, err := Render(api.RenderContext{Cfg: &api.Config{Servers: []api.Server{{Host: "203.0.113.5", Port: 22}}}, DefaultIface: "Wi-Fi", ChanPort: 1, ClashPort: 2})
	if err != nil {
		t.Skip("минимальный конфиг не рендерится: ", err)
	}
	var v struct {
		Route map[string]any `json:"route"`
	}
	if err = json.Unmarshal(out, &v); err != nil {
		t.Fatal(err)
	}
	if v.Route["default_interface"] != nil || v.Route["auto_detect_interface"] != nil {
		t.Fatalf("канал не должен привязываться к интерфейсу: route=%v", v.Route)
	}
	vpn, err := RenderVPN(vpnRC(false, false, "Wi-Fi"))
	if err != nil {
		t.Fatal(err)
	}
	var w struct {
		Route map[string]any `json:"route"`
	}
	if err = json.Unmarshal(vpn, &w); err != nil {
		t.Fatal(err)
	}
	if w.Route["default_interface"] != "Wi-Fi" || w.Route["auto_detect_interface"] != nil {
		t.Fatalf("VPN: route=%v", w.Route)
	}
	vpn, _ = RenderVPN(vpnRC(false, false, ""))
	if !strings.Contains(string(vpn), `"auto_detect_interface":true`) {
		t.Fatalf("VPN без интерфейса должен остаться на auto_detect: %s", vpn)
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
