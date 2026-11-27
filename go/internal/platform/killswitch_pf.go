package platform

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
)

// Этап 4: галочка «выход только через наш адрес» на macOS — pf-якорь.
//
// Правила безопасности (ГЛАВНОЕ ТРЕБОВАНИЕ владельца: выключить можно всегда):
//   - основной pf.conf и ЧУЖИЕ якоря не трогаем; пишем только в свой якорь PFAnchor (дочерний com.apple/*, который уже
//     вычисляется штатным набором правил macOS: `anchor "com.apple/*"`; если набор правил другой — якорь не действует,
//     об этом сообщаем, а не пытаемся править чужое);
//   - pf включаем через `pfctl -E` с токеном и снимаем только свой токен (`pfctl -X`): если pf был выключен до нас — станет
//     выключен, если был включён — останется включён;
//   - токен лежит в файле состояния; ничего постоянного в системе: якорь снимают выключение, выход, сторож при смерти/убийстве
//     ядра (runCleanup) и старт программы (ReleasePF).

// PFAnchor — свой якорь.
const PFAnchor = "com.apple/remoteagents-killswitch"

const pfStateFile = "pf-killswitch.json"

// PFRun — исполнитель pfctl (подменяется в тестах): stdin, аргументы → объединённый вывод.
type PFRun func(ctx context.Context, stdin string, args ...string) (string, error)

func execPF(ctx context.Context, stdin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "pfctl", args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// PFKillSwitch — управление якорем. Состояние (токен pf) хранится в файле, поэтому снять может и другой процесс (сторож).
type PFKillSwitch struct {
	Run   PFRun
	State string // путь файла состояния
	mu    sync.Mutex
}

type pfState struct {
	Token string `json:"token"`
}

// NewPFKillSwitch — реальный исполнитель pfctl; stateDir — каталог состояния программы.
func NewPFKillSwitch(stateDir string) *PFKillSwitch {
	return &PFKillSwitch{Run: execPF, State: filepath.Join(stateDir, pfStateFile)}
}

// PFSupported — pf есть только на macOS.
func PFSupported() bool { return pfSupported }

var (
	tunNameRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,31}$`)
	tokenRe   = regexp.MustCompile(`(?i)token\s*:\s*(\d+)`)
)

var pfPrivateV4 = []string{"127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"}
var pfPrivateV6 = []string{"::1/128", "fe80::/10", "fc00::/7", "ff00::/8"}

// PFRules — текст правил якоря: пропускаем loopback, наш tun, DHCP, частные сети и адреса серверов; всё остальное — block.
// Адреса проверяются (netip): в правила попадает только корректный IP/сеть.
func PFRules(tun string, servers []string) (string, error) {
	if !tunNameRe.MatchString(tun) {
		return "", fmt.Errorf("pf: некорректное имя интерфейса %q", tun)
	}
	var v4, v6 []string
	seen := map[string]bool{}
	for _, s := range servers {
		s = strings.TrimSpace(s)
		var p netip.Prefix
		if ip, err := netip.ParseAddr(s); err == nil {
			p = netip.PrefixFrom(ip.WithZone(""), ip.BitLen())
		} else if pp, err := netip.ParsePrefix(s); err == nil {
			p = pp
		} else {
			continue
		}
		if seen[p.String()] {
			continue
		}
		seen[p.String()] = true
		if p.Addr().Is4() {
			v4 = append(v4, p.String())
		} else {
			v6 = append(v6, p.String())
		}
	}
	sort.Strings(v4)
	sort.Strings(v6)
	var b strings.Builder
	b.WriteString("pass out quick on lo0 all\n")
	fmt.Fprintf(&b, "pass out quick on %s all\n", tun)
	b.WriteString("pass out quick inet proto udp from any port 68 to any port 67\n")
	b.WriteString("pass out quick inet6 proto udp from any port 546 to any port 547\n")
	fmt.Fprintf(&b, "pass out quick inet to { %s }\n", strings.Join(pfPrivateV4, ", "))
	fmt.Fprintf(&b, "pass out quick inet6 to { %s }\n", strings.Join(pfPrivateV6, ", "))
	if len(v4) > 0 {
		fmt.Fprintf(&b, "pass out quick inet to { %s }\n", strings.Join(v4, ", "))
	}
	if len(v6) > 0 {
		fmt.Fprintf(&b, "pass out quick inet6 to { %s }\n", strings.Join(v6, ", "))
	}
	b.WriteString("block drop out quick all\n")
	return b.String(), nil
}

func (k *PFKillSwitch) load() pfState {
	var st pfState
	if b, err := os.ReadFile(k.State); err == nil {
		_ = json.Unmarshal(b, &st)
	}
	return st
}

func (k *PFKillSwitch) save(st pfState) error {
	if err := os.MkdirAll(filepath.Dir(k.State), 0700); err != nil {
		return err
	}
	b, _ := json.Marshal(st)
	return os.WriteFile(k.State, b, 0600)
}

// Apply ставит (или перезагружает при смене сети/адреса tun) правила в своём якоре. Любая неудача снимает всё, что успели поставить.
func (k *PFKillSwitch) Apply(ctx context.Context, tun string, servers []string) error {
	rules, err := PFRules(tun, servers)
	if err != nil {
		return err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	st := k.load()
	if st.Token == "" {
		out, err := k.Run(ctx, "", "-E")
		m := tokenRe.FindStringSubmatch(out)
		if m != nil {
			st.Token = m[1]
			if serr := k.save(st); serr != nil && err == nil {
				err = serr
			}
		}
		if err != nil || m == nil {
			if m != nil {
				_ = k.releaseLocked(ctx)
			}
			if err == nil {
				err = errors.New("pfctl -E не вернул токен")
			}
			return fmt.Errorf("pf: включение: %w", err)
		}
	}
	if _, err := k.Run(ctx, rules, "-a", PFAnchor, "-f", "-"); err != nil {
		_ = k.releaseLocked(ctx)
		return fmt.Errorf("pf: загрузка правил: %w", err)
	}
	// Якорь действует, только если основной набор правил его вычисляет (штатный macOS: anchor "com.apple/*").
	if out, err := k.Run(ctx, "", "-sr"); err != nil || !strings.Contains(out, `"com.apple/*"`) {
		_ = k.releaseLocked(ctx)
		return errors.New(`pf: основной набор правил не вычисляет anchor "com.apple/*", блок не действует (чужой pf.conf не трогаем)`)
	}
	return nil
}

// Release снимает свой якорь и свой токен pf. Безопасно вызывать сколько угодно раз и из другого процесса.
func (k *PFKillSwitch) Release(ctx context.Context) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.releaseLocked(ctx)
}

func (k *PFKillSwitch) releaseLocked(ctx context.Context) error {
	st := k.load()
	var first error
	if st.Token == "" {
		// Состояния нет: чужое не трогаем; свой якорь чистим, только если в нём что-то осталось (например, состояние потеряно).
		out, err := k.Run(ctx, "", "-a", PFAnchor, "-sr")
		if err != nil || strings.TrimSpace(out) == "" {
			return nil
		}
	}
	if _, err := k.Run(ctx, "", "-a", PFAnchor, "-F", "all"); err != nil {
		first = fmt.Errorf("pf: снятие якоря: %w", err)
	}
	if st.Token != "" {
		if _, err := k.Run(ctx, "", "-X", st.Token); err != nil && first == nil {
			first = fmt.Errorf("pf: снятие токена: %w", err)
		}
	}
	// Токен наш и одноразовый: файл убираем всегда, чтобы неудача не залипала навсегда.
	if err := os.Remove(k.State); err != nil && !os.IsNotExist(err) && first == nil {
		first = err
	}
	return first
}

// ReleasePF — снять якорь/токен из любого процесса (сторож при смерти ядра, старт программы). Не macOS — ничего.
func ReleasePF(ctx context.Context, stateDir string) error {
	if !pfSupported {
		return nil
	}
	return NewPFKillSwitch(stateDir).Release(ctx)
}

// TunIfaceByAddr — имя интерфейса с адресом на prefix (на macOS номер utunN выдаёт ОС, по имени ra3-… его не найти).
func TunIfaceByAddr(ifs []api.Iface, prefix string) string {
	for _, f := range ifs {
		for _, a := range f.Addrs {
			if strings.HasPrefix(a, prefix) {
				return f.Name
			}
		}
	}
	return ""
}
