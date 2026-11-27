package supervise

import (
	"testing"

	"remoteagents/internal/api"
)

// Принудительное выключение: маркер на следующий запуск ядра читается один раз и стирается (ничего постоянного не остаётся); цикл сторожа получает сигнал.
func TestForceVPNOffMarkerOnce(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	if TakeVPNOff(p) {
		t.Fatal("маркера ещё нет")
	}
	if err := ForceVPNOff(p); err != nil {
		t.Fatal(err)
	}
	select {
	case <-forceVPNOff:
	default:
		t.Fatal("сторож не получил сигнал")
	}
	if !TakeVPNOff(p) {
		t.Fatal("маркер должен быть")
	}
	if TakeVPNOff(p) {
		t.Fatal("маркер должен стираться после чтения")
	}
}
