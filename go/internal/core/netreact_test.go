package core

import (
	"context"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func TestDebounceCoalescesBurst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	in := make(chan struct{})
	out := debounce(ctx, in, 50*time.Millisecond)
	for i := 0; i < 20; i++ {
		in <- struct{}{}
		time.Sleep(2 * time.Millisecond)
	}
	select {
	case <-out:
	case <-time.After(2 * time.Second):
		t.Fatal("нет события после тишины")
	}
	select {
	case <-out:
		t.Fatal("пачка не слита в одно событие")
	case <-time.After(120 * time.Millisecond):
	}
}

func wifi(addr string) api.Iface {
	return api.Iface{Name: "Wi-Fi", Up: true, DefaultRoute: true, Metric: 30, Addrs: []string{addr}}
}

// Tailscale/Happ/Hyper-V меняют адреса и маршруты постоянно — отпечаток физической сети не меняется.
func TestNetSignatureIgnoresForeignAdapters(t *testing.T) {
	ts := api.Iface{Name: "Tailscale", Up: true, DefaultRoute: true, Metric: 1, Addrs: []string{"100.64.0.1"}}
	a := netSignature([]api.Iface{wifi("192.168.1.5"), ts})
	ts.Addrs = []string{"100.64.0.9"}
	b := netSignature([]api.Iface{wifi("192.168.1.5"), ts, {Name: "happ-tun", Up: true, DefaultRoute: true, Metric: 0, Addrs: []string{"10.1.1.1"}}})
	if a != b || a == "" {
		t.Fatalf("a=%q b=%q", a, b)
	}
	if c := netSignature([]api.Iface{wifi("10.0.0.7")}); c == a {
		t.Fatal("смена адреса физического адаптера не замечена")
	}
}

func TestNetReactRebuildsOnlyOnRealChangeOrDownChannel(t *testing.T) {
	sig, up := "wifi|1", true
	var sb, ch int
	n := &netReact{log: &fake.Logger{}, sig: func() string { return sig }, chUp: func() bool { return up },
		sbReset: func(context.Context) { sb++ }, chReset: func() { ch++ }}
	n.last, n.inited = sig, true
	if n.onChange(context.Background()) || sb+ch != 0 {
		t.Fatal("лишняя перестройка при той же сети и живом канале")
	}
	sig = "eth|2" // Wi-Fi → другая сеть
	if !n.onChange(context.Background()) || sb != 1 || ch != 1 {
		t.Fatalf("смена сети не обработана sb=%d ch=%d", sb, ch)
	}
	up = false // канал лежит — любое событие сети перестраивает
	if !n.onChange(context.Background()) || sb != 2 || ch != 2 {
		t.Fatalf("sb=%d ch=%d", sb, ch)
	}
}
