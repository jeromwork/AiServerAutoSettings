//go:build linux

package platform

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Правила галочки «только через наш адрес» на Linux ставит сам sing-box (strict_route + auto_redirect: таблица nftables
// `sing-box` и ip rule с приоритетами 9000–9010) и снимает при штатном выходе. Убитый процесс (SIGKILL, падение, kill ядра)
// их оставляет — а таблица с redirect на мёртвый порт режет весь интернет. Поэтому: правила есть только у живого sing-box,
// остальное убирается этой функцией (старт ядра, выход, падение/остановка процесса VPN, перед запуском VPN).

const (
	sweepRulePrefMin = 9000
	sweepRulePrefMax = 9010
	sweepTimeout     = 5 * time.Second
)

// Подменяются в тестах.
var (
	sweepExec  = realSweepExec
	sweepComms = liveComms
)

// realSweepExec — в тестовых бинарниках системные команды не запускаем никогда (nft/ip на хосте разработки).
func realSweepExec(ctx context.Context, name string, args ...string) ([]byte, error) {
	if testing.Testing() {
		return nil, errors.New("sweep: system commands are disabled in tests")
	}
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// liveComms — имена (comm) всех живых процессов из /proc.
func liveComms() []string {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/comm")
		if err != nil {
			continue
		}
		out = append(out, strings.TrimSpace(string(b)))
	}
	return out
}

// SweepVPNLock снимает остатки nft-таблицы sing-box и ip rule 9000–9010, если не осталось живого sing-box, которому они принадлежат.
// Живой процесс VPN (ra-vpn) или чужой sing-box — правила его, не трогаем. ip rule трогаем только если нет и ядра/LAN (ra-core), у них те же приоритеты.
func SweepVPNLock(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, sweepTimeout)
	defer cancel()
	vpn, anyBox := false, false
	for _, c := range sweepComms() {
		switch c {
		case "ra-vpn", "sing-box":
			vpn, anyBox = true, true
		case "ra-core":
			anyBox = true
		}
	}
	var errs []error
	if !vpn {
		errs = append(errs, sweepNft(ctx))
	}
	if !anyBox {
		errs = append(errs, sweepIPRules(ctx))
	}
	return errors.Join(errs...)
}

func sweepNft(ctx context.Context) error {
	out, err := sweepExec(ctx, "nft", "list", "tables")
	if err != nil {
		return nil // нет nft или нет прав — нечего убирать
	}
	var errs []error
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) == 3 && f[0] == "table" && f[2] == "sing-box" && (f[1] == "inet" || f[1] == "ip" || f[1] == "ip6") {
			if o, err := sweepExec(ctx, "nft", "delete", "table", f[1], "sing-box"); err != nil {
				errs = append(errs, errors.New("nft delete table "+f[1]+" sing-box: "+strings.TrimSpace(string(o))))
			}
		}
	}
	return errors.Join(errs...)
}

func sweepIPRules(ctx context.Context) error {
	var errs []error
	for _, fam := range []string{"-4", "-6"} {
		out, err := sweepExec(ctx, "ip", fam, "rule", "show")
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(out), "\n") {
			i := strings.Index(line, ":")
			if i <= 0 {
				continue
			}
			pref, err := strconv.Atoi(strings.TrimSpace(line[:i]))
			if err != nil || pref < sweepRulePrefMin || pref > sweepRulePrefMax {
				continue
			}
			if o, err := sweepExec(ctx, "ip", fam, "rule", "del", "pref", strconv.Itoa(pref)); err != nil {
				errs = append(errs, errors.New("ip rule del pref "+strconv.Itoa(pref)+": "+strings.TrimSpace(string(o))))
			}
		}
	}
	return errors.Join(errs...)
}
