//go:build linux

package platform

import (
	"context"
	"encoding/json"
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
	sweepExec     = realSweepExec
	sweepProcs    = liveProcs
	sweepReadFile = os.ReadFile
)

// realSweepExec — в тестовых бинарниках системные команды не запускаем никогда (nft/ip на хосте разработки).
func realSweepExec(ctx context.Context, name string, args ...string) ([]byte, error) {
	if testing.Testing() {
		return nil, errors.New("sweep: system commands are disabled in tests")
	}
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// sweepProc — живой процесс: comm и аргументы командной строки.
type sweepProc struct {
	comm string
	args []string
}

// liveProcs — все живые процессы из /proc (comm + cmdline).
func liveProcs() []sweepProc {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var out []sweepProc
	for _, e := range ents {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/comm")
		if err != nil {
			continue
		}
		c, _ := os.ReadFile("/proc/" + e.Name() + "/cmdline")
		out = append(out, sweepProc{comm: strings.TrimSpace(string(b)), args: strings.Split(strings.TrimRight(string(c), "\x00"), "\x00")})
	}
	return out
}

// holdsTun — процесс sing-box, который держит TUN (а значит, и свои правила ОС): в его конфиге (`run -c <файл>`) есть inbound type=tun.
// Канальный sing-box (ra-core без TUN) правил не держит и уборку не блокирует. Нечитаемый конфиг: чужой sing-box — считаем держателем
// (чужое не трогаем), наш ra-core/ra-vpn — нет.
func holdsTun(p sweepProc) bool {
	ours := p.comm == "ra-core" || p.comm == "ra-vpn"
	cfg := ""
	for i, a := range p.args {
		if (a == "-c" || a == "--config") && i+1 < len(p.args) {
			cfg = p.args[i+1]
		}
	}
	if cfg == "" {
		return !ours
	}
	b, err := sweepReadFile(cfg)
	if err != nil {
		return !ours
	}
	var doc struct {
		Inbounds []struct {
			Type string `json:"type"`
		} `json:"inbounds"`
	}
	if json.Unmarshal(b, &doc) != nil {
		return !ours
	}
	for _, in := range doc.Inbounds {
		if in.Type == "tun" {
			return true
		}
	}
	return false
}

// SweepVPNLock снимает остатки nft-таблицы sing-box и ip rule 9000–9010, если не осталось живого sing-box с TUN, которому они принадлежат.
// Таблицу держит живой ra-vpn или чужой sing-box с TUN; ip rule — любой sing-box с TUN (LAN ядра ra-core тоже ставит 9000+).
// Канальный sing-box без TUN уборку не блокирует.
func SweepVPNLock(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, sweepTimeout)
	defer cancel()
	vpn, anyTun := false, false
	for _, p := range sweepProcs() {
		switch p.comm {
		case "ra-vpn", "sing-box", "ra-core":
			if !holdsTun(p) {
				continue
			}
			anyTun = true
			if p.comm != "ra-core" {
				vpn = true
			}
		}
	}
	var errs []error
	if !vpn {
		errs = append(errs, sweepNft(ctx))
	}
	if !anyTun {
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
