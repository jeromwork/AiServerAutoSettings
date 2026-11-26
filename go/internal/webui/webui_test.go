package webui

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"remoteagents/internal/api/fake"
)

type applyAct struct {
	fake.Actions
	onApply func(ctx context.Context)
}

func (a *applyAct) ConfigApply(ctx context.Context, data []byte, pw string) error {
	a.onApply(ctx)
	return nil
}

func start(t *testing.T, act *applyAct) (*UI, context.CancelFunc) {
	t.Helper()
	u, err := New(act, &fake.Logger{}, "")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	if err := u.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cancel)
	return u, cancel
}

// Причина вечного «Применяю...»: ответ на «Применить» терялся, потому что ядро отменяет контекст страницы
// (перезапуск) раньше, чем ответ записан, а страница закрывалась жёстко.
func TestApplyReplySurvivesCoreShutdown(t *testing.T) {
	var cancel context.CancelFunc
	act := &applyAct{onApply: func(ctx context.Context) {
		cancel()
		time.Sleep(200 * time.Millisecond)
	}}
	u, c := start(t, act)
	cancel = c
	resp, err := http.PostForm("http://127.0.0.1:"+itoa(u.Port())+"/api/config/apply?t="+u.Token(), url.Values{"text": {"{}"}})
	if err != nil {
		t.Fatalf("ответ потерян: %v", err)
	}
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), `"ok":true`) {
		t.Fatalf("body=%s", b)
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

func TestEventsReplayAndLive(t *testing.T) {
	u, _ := start(t, &applyAct{})
	u.Publish("apply", map[string]string{"stage": "error", "text": "имя ПК должно быть латиницей"})
	resp, err := http.Get("http://127.0.0.1:" + itoa(u.Port()) + "/api/events?t=" + u.Token())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	rd := bufio.NewReader(resp.Body)
	read := func() string {
		var sb strings.Builder
		for {
			line, err := rd.ReadString('\n')
			if err != nil {
				t.Fatal(err)
			}
			if line == "\n" {
				if sb.Len() > 0 {
					return sb.String()
				}
				continue
			}
			sb.WriteString(line)
		}
	}
	read() // retry:
	if got := read(); !strings.Contains(got, "event: apply") || !strings.Contains(got, "латиницей") {
		t.Fatalf("нет повтора последнего события: %q", got)
	}
	u.Publish("channel", map[string]string{"state": "up"})
	if got := read(); !strings.Contains(got, "event: channel") {
		t.Fatalf("нет живого события: %q", got)
	}
}

func TestEventsNeedAuth(t *testing.T) {
	u, _ := start(t, &applyAct{})
	resp, err := http.Get("http://127.0.0.1:" + itoa(u.Port()) + "/api/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("code=%d", resp.StatusCode)
	}
}

func TestCallTimeout(t *testing.T) {
	block := make(chan struct{})
	defer close(block)
	err := callTimeout(50*time.Millisecond, "применение конфига", func() error { <-block; return nil })
	if err == nil || !strings.Contains(err.Error(), "не завершилось") {
		t.Fatalf("err=%v", err)
	}
}

// Страница, подключившаяся позже, получает ТЕКУЩЕЕ состояние из снимка, а не устаревшее последнее событие.
func TestEventsSnapshotIsCurrentNotLastPublished(t *testing.T) {
	u, _ := start(t, &applyAct{})
	u.Publish("apply", map[string]string{"stage": "checking"}) // устарело
	u.SetSnapshot(func() map[string]any { return map[string]any{"apply": map[string]string{"stage": "ready"}} })
	resp, err := http.Get("http://127.0.0.1:" + itoa(u.Port()) + "/api/events?t=" + u.Token())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	rd := bufio.NewReader(resp.Body)
	var got strings.Builder
	for i := 0; i < 5; i++ {
		l, err := rd.ReadString('\n')
		if err != nil {
			break
		}
		got.WriteString(l)
		if strings.Contains(l, "data:") {
			break
		}
	}
	if !strings.Contains(got.String(), `"stage":"ready"`) || strings.Contains(got.String(), "checking") {
		t.Fatalf("получено: %q", got.String())
	}
}
