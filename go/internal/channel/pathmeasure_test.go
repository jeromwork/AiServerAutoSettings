package channel

import (
	"strings"
	"testing"
	"time"

	"remoteagents/internal/api/fake"
)

func noBad(string) bool { return false }

func TestPickFastest(t *testing.T) {
	p, ok := pickByMeasure([]string{"a", "b", "c"}, map[string]int{"a": 200, "b": 80, "c": 120}, noBad, "")
	if !ok || p != "b" {
		t.Fatal(p, ok)
	}
}

func TestPickSkipsBadAndFailed(t *testing.T) {
	p, _ := pickByMeasure([]string{"a", "b", "c"}, map[string]int{"b": 50, "c": 120}, func(n string) bool { return n == "b" }, "")
	if p != "c" {
		t.Fatal(p)
	}
}

func TestPickHysteresis(t *testing.T) {
	names := []string{"a", "b"}
	// выигрыш 20% и 20 мс — остаёмся
	if p, _ := pickByMeasure(names, map[string]int{"a": 100, "b": 80}, noBad, "a"); p != "a" {
		t.Fatal("дёрнули живой путь", p)
	}
	// 40% , но всего 20 мс — остаёмся
	if p, _ := pickByMeasure(names, map[string]int{"a": 50, "b": 30}, noBad, "a"); p != "a" {
		t.Fatal("мало мс", p)
	}
	// 50% и 100 мс — уходим
	if p, _ := pickByMeasure(names, map[string]int{"a": 200, "b": 100}, noBad, "a"); p != "b" {
		t.Fatal("не ушли", p)
	}
	// текущий не ответил — уходим сразу
	if p, _ := pickByMeasure(names, map[string]int{"b": 500}, noBad, "a"); p != "b" {
		t.Fatal(p)
	}
}

func TestPickNoMeasureFallsToRank(t *testing.T) {
	if _, ok := pickByMeasure([]string{"a", "b"}, map[string]int{}, noBad, ""); ok {
		t.Fatal("ожидался отказ")
	}
	sb := &selectorSB{names: []string{"a", "b"}, now: "b", addr: map[string]string{}}
	c := &chn{sb: sb, log: &fake.Logger{}, measureFn: func([]string) map[string]int { return nil }}
	c.badUntil = map[string]time.Time{"a": time.Now().Add(time.Minute)}
	if got := c.selectBest(""); got != "b" || sb.now != "b" {
		t.Fatal("fallback по рангу с учётом bad:", got)
	}
}

func TestSelectBestAppliesMeasure(t *testing.T) {
	sb := &selectorSB{names: []string{"a", "b"}, now: "a", addr: map[string]string{}}
	c := &chn{sb: sb, log: &fake.Logger{}, measureFn: func([]string) map[string]int { return map[string]int{"a": 300, "b": 60} }}
	if c.selectBest("") != "b" || sb.now != "b" {
		t.Fatal("не выбран быстрый путь")
	}
	c.pinned = time.Now().Add(time.Minute)
	sb.now = "a"
	if c.selectBest("") != "" || sb.now != "a" {
		t.Fatal("закреплённый путь тронут")
	}
}

func TestSetRankWinnerFirstOnlyPassed(t *testing.T) {
	c := &chn{}
	c.setRank([]string{"a", "b", "c"}, map[string]int{"a": 300, "b": 60}, "a")
	if got := strings.Join(c.PathRank(), ","); got != "a,b" {
		t.Fatalf("победитель первым, без упавших: %s", got)
	}
}
