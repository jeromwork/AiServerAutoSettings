package platform

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type pfFake struct {
	calls  []string
	stdins []string
	token  string
	anchor bool // в якоре есть правила
	evalOK bool // основной набор правил вычисляет com.apple/*
	failOn string
	tokens int
}

func (f *pfFake) run(_ context.Context, stdin string, args ...string) (string, error) {
	cmd := strings.Join(args, " ")
	f.calls = append(f.calls, cmd)
	f.stdins = append(f.stdins, stdin)
	if f.failOn != "" && strings.Contains(cmd, f.failOn) {
		return "", errors.New("boom")
	}
	switch {
	case cmd == "-E":
		f.tokens++
		return "pf enabled\nToken : 4242\n", nil
	case strings.HasPrefix(cmd, "-X"):
		f.tokens--
	case strings.Contains(cmd, "-f -"):
		f.anchor = true
	case strings.Contains(cmd, "-F all"):
		f.anchor = false
	case strings.Contains(cmd, "-a "+PFAnchor+" -sr"):
		if f.anchor {
			return "block drop out quick all\n", nil
		}
	case cmd == "-sr":
		if f.evalOK {
			return "anchor \"com.apple/*\" all\n", nil
		}
		return "block drop all\n", nil
	}
	return "", nil
}

func newPF(t *testing.T, f *pfFake) *PFKillSwitch {
	return &PFKillSwitch{Run: f.run, State: filepath.Join(t.TempDir(), "pf.json")}
}

func TestPFRulesShape(t *testing.T) {
	r, err := PFRules("utun7", []string{"203.0.113.5", "2001:db8::1", "bad; pass all", "203.0.113.5", "198.51.100.0/24"})
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(r), "\n")
	if lines[len(lines)-1] != "block drop out quick all" {
		t.Fatalf("последнее правило не block: %q", lines[len(lines)-1])
	}
	for _, want := range []string{"pass out quick on lo0 all", "pass out quick on utun7 all", "port 67", "10.0.0.0/8", "192.168.0.0/16",
		"203.0.113.5/32", "198.51.100.0/24", "2001:db8::1/128", "fe80::/10"} {
		if !strings.Contains(r, want) {
			t.Errorf("нет %q в правилах:\n%s", want, r)
		}
	}
	if strings.Contains(r, "bad") || strings.Count(r, "203.0.113.5/32") != 1 {
		t.Errorf("мусор/дубль в правилах:\n%s", r)
	}
	if _, err := PFRules("utun7 all; pass", nil); err == nil {
		t.Error("некорректное имя интерфейса должно отклоняться")
	}
	if _, err := PFRules("", nil); err == nil {
		t.Error("пустое имя интерфейса должно отклоняться")
	}
}

func TestPFApplyOnlyOwnAnchorAndReleaseRestores(t *testing.T) {
	f := &pfFake{evalOK: true}
	k := newPF(t, f)
	if err := k.Apply(context.Background(), "utun7", []string{"203.0.113.5"}); err != nil {
		t.Fatal(err)
	}
	for _, c := range f.calls {
		if strings.Contains(c, "-f ") && !strings.Contains(c, "-a "+PFAnchor) {
			t.Errorf("загрузка правил мимо своего якоря: %s", c)
		}
		if strings.Contains(c, "-d") || strings.Contains(c, "-F all") && !strings.Contains(c, PFAnchor) {
			t.Errorf("опасная команда: %s", c)
		}
	}
	if !f.anchor || f.tokens != 1 {
		t.Fatalf("anchor=%v tokens=%d", f.anchor, f.tokens)
	}
	// перезагрузка при смене сети: второй -E не делается
	if err := k.Apply(context.Background(), "utun8", []string{"203.0.113.5"}); err != nil || f.tokens != 1 {
		t.Fatalf("reload: err=%v tokens=%d", err, f.tokens)
	}
	if err := k.Release(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.anchor || f.tokens != 0 {
		t.Fatalf("после Release anchor=%v tokens=%d", f.anchor, f.tokens)
	}
	if _, err := os.Stat(k.State); !os.IsNotExist(err) {
		t.Error("файл состояния должен быть удалён")
	}
	if c := f.calls[len(f.calls)-1]; c != "-X 4242" {
		t.Errorf("снимается именно свой токен, последняя команда %q", c)
	}
}

func TestPFReleaseFromAnotherProcessAndIdempotent(t *testing.T) {
	f := &pfFake{evalOK: true}
	k := newPF(t, f)
	if err := k.Apply(context.Background(), "utun7", nil); err != nil {
		t.Fatal(err)
	}
	// «сторож» — другой экземпляр с тем же файлом состояния
	g := &PFKillSwitch{Run: f.run, State: k.State}
	if err := g.Release(context.Background()); err != nil || f.anchor || f.tokens != 0 {
		t.Fatalf("err=%v anchor=%v tokens=%d", err, f.anchor, f.tokens)
	}
	n := len(f.calls)
	if err := g.Release(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, c := range f.calls[n:] {
		if strings.Contains(c, "-F") || strings.Contains(c, "-X") {
			t.Errorf("повторный Release без состояния ничего не снимает: %s", c)
		}
	}
}

func TestPFReleaseCleansLeftoverAnchorWithoutState(t *testing.T) {
	f := &pfFake{anchor: true}
	k := newPF(t, f)
	if err := k.Release(context.Background()); err != nil || f.anchor {
		t.Fatalf("остаток якоря не убран: err=%v anchor=%v", err, f.anchor)
	}
}

func TestPFApplyFailureUndoesEverything(t *testing.T) {
	// правила не загрузились → pf возвращён как был
	f := &pfFake{evalOK: true, failOn: "-f -"}
	k := newPF(t, f)
	if err := k.Apply(context.Background(), "utun7", nil); err == nil {
		t.Fatal("ожидалась ошибка")
	}
	if f.anchor || f.tokens != 0 {
		t.Fatalf("анкор=%v токены=%d", f.anchor, f.tokens)
	}
	// чужой набор правил без anchor "com.apple/*" → блок не действует, всё снято
	f = &pfFake{evalOK: false}
	k = newPF(t, f)
	if err := k.Apply(context.Background(), "utun7", nil); err == nil || f.anchor || f.tokens != 0 {
		t.Fatalf("err=%v anchor=%v tokens=%d", err, f.anchor, f.tokens)
	}
}

func TestPFReleaseKeepsGoingOnError(t *testing.T) {
	// снятие якоря не удалось — токен всё равно снимается, ошибка возвращается, состояние не залипает
	f := &pfFake{evalOK: true}
	k := newPF(t, f)
	if err := k.Apply(context.Background(), "utun7", nil); err != nil {
		t.Fatal(err)
	}
	f.failOn = "-F all"
	if err := k.Release(context.Background()); err == nil {
		t.Fatal("ошибка снятия якоря должна вернуться")
	}
	if f.tokens != 0 {
		t.Fatalf("токен не снят: %d", f.tokens)
	}
}
