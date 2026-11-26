package singbox

import (
	"context"
	"errors"
	"fmt"
	"net"
	"testing"

	"remoteagents/internal/api/fake"
)

// Причина: Windows запрещает UDP-bind в зарезервированных диапазонах, а проверка только TCP порт пропускала.
func TestAllocPortsSkipsPortWithForbiddenUDP(t *testing.T) {
	old := bindCheck
	defer func() { bindCheck = old }()
	var bad int
	bindCheck = func(port int) error {
		if bad == 0 {
			bad = port
		}
		if port == bad {
			return errors.New("bind: forbidden by its access permissions")
		}
		return old(port)
	}
	ports, err := allocPorts(2)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range ports {
		if p == bad {
			t.Fatalf("выбран запрещённый порт %d", p)
		}
	}
	if ports[0] == ports[1] {
		t.Fatal("порты совпали")
	}
}

func TestBindCheckSeesBusyUDP(t *testing.T) {
	u, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer u.Close()
	if bindCheck(u.LocalAddr().(*net.UDPAddr).Port) == nil {
		t.Fatal("занятый UDP-порт принят")
	}
}

// Первый запуск sing-box падает из-за порта (bind запрещён) — берутся другие порты, второй запуск проходит.
func TestStartRetriesOnOtherPortAfterBindFailure(t *testing.T) {
	old := bindCheck
	defer func() { bindCheck = old }()
	ready := make(chan struct{})
	s := &box{ready: ready, vReady: ready, log: &fake.Logger{}}
	if err := s.reallocPorts(); err != nil {
		t.Fatal(err)
	}
	first := s.rc.ChanPort
	forbidden := first
	bindCheck = func(port int) error {
		if port == forbidden {
			return errors.New("forbidden")
		}
		return nil
	}
	calls := 0
	s.applyHook = func(context.Context) error {
		calls++
		if calls == 1 {
			forbidden = s.rc.ChanPort // порт стал недоступен уже после запуска
			return fmt.Errorf("singbox: start: exit 1: %w", errEarlyExit)
		}
		return nil
	}
	if err := s.startWithPorts(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || s.rc.ChanPort == first || s.ChanAddr() == fmt.Sprintf("127.0.0.1:%d", first) {
		t.Fatalf("calls=%d chan=%d first=%d", calls, s.rc.ChanPort, first)
	}
}

// Если порты в порядке, ошибка запуска не повторяется вслепую.
func TestStartDoesNotRetryWhenPortsFine(t *testing.T) {
	old := bindCheck
	defer func() { bindCheck = old }()
	bindCheck = func(int) error { return nil }
	s := &box{vReady: make(chan struct{}), ready: make(chan struct{}), log: &fake.Logger{}}
	calls := 0
	s.applyHook = func(context.Context) error { calls++; return fmt.Errorf("x: %w", errEarlyExit) }
	if err := s.startWithPorts(context.Background()); err == nil || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}
