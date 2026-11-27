package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/config"
	"remoteagents/internal/journal"
)

// Данные для страницы (SSE) очищаются теми же правилами, что журнал: зарегистрированные секреты → ***,
// плюс любые IP-адреса и имена хостов (с портом) — страница их не показывает.
var (
	reIP4  = regexp.MustCompile(`\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b`)
	reIP6  = regexp.MustCompile(`\[?(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\]?(?::\d{1,5})?|\[?(?:[0-9A-Fa-f]{0,4}:){1,6}:[0-9A-Fa-f]{0,4}\]?`)
	reHost = regexp.MustCompile(`\b[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?::\d{1,5})?\b`)
)

func sanitize(s string) string {
	s = journal.MaskString(s)
	s = reIP6.ReplaceAllString(s, "***")
	s = reIP4.ReplaceAllString(s, "***")
	s = reHost.ReplaceAllString(s, "***")
	return s
}

// checkPCName — имя ПК для сервера из имени в конфиге (или --pc) должно получиться допустимым.
func checkPCName(flagPC, cfgName string) error {
	pc := flagPC
	if pc == "" {
		pc = pcNameFor(cfgName)
	}
	if pc == "" {
		return fmt.Errorf("имя компьютера в конфиге должно быть латиницей (буквы, цифры, . _ -): из «%s» не получилось допустимое имя", sanitize(strings.TrimSpace(cfgName)))
	}
	if !pcNameRe.MatchString(pc) {
		return fmt.Errorf("имя компьютера для сервера «%s» недопустимо: нужны латиница, цифры, . _ - (до 64 знаков, первый знак буква или цифра)", sanitize(pc))
	}
	return nil
}

// validateConfig — всё, что можно проверить до применения: пароль/формат и имя ПК.
func (c *core) validateConfig(data []byte, password string) error {
	cfg, key, err := config.Open(data, password)
	if err != nil {
		return err
	}
	clear(key)
	if c.f.Mode.NoChannel {
		return nil
	}
	return checkPCName(c.f.PC, cfg.Name)
}

// explainApplyErr — понятный русский текст ошибки применения для страницы.
func (c *core) explainApplyErr(err error) string {
	switch {
	case errors.Is(err, config.ErrPending):
		left := ""
		if ptr, e := config.ReadPointers(c.p); e == nil && ptr.Switch != nil {
			left = fmt.Sprintf(" (осталось около %d с)", max(int(time.Until(ptr.Switch.Deadline).Seconds()), 0))
		}
		return "Идёт пробное окно" + left + ": дождитесь подтверждения или отката (снять галочку и выключить VPN можно в любой момент)."
	case errors.Is(err, api.ErrBusy):
		return "Программа занята другой операцией (обновление или применение). Повторите через несколько секунд."
	}
	return sanitize(err.Error())
}

type attempt struct {
	N      int    `json:"n"`
	At     string `json:"at"`
	Path   string `json:"path"`
	State  string `json:"state"` // trying | ok | error
	Reason string `json:"reason,omitempty"`
}

type events struct {
	mu       sync.Mutex
	attempts []attempt
	n        int
	kick     chan struct{}
	update   map[string]any // ход обновления/отката версии (событие "update")
	apply    map[string]any // последнее состояние применения (для снимка при подключении страницы)
	paths    map[string]any
}

func (c *core) publish(kind string, data any) {
	if ui := c.ui; ui != nil {
		ui.Publish(kind, data)
	}
}

// publishStatus — сводка для страницы: то же, что /state, но с очищенными причинами.
func (c *core) publishStatus() { c.publish("status", c.Status()) }

// trialState — пробное окно нового конфига: идёт ли и до какого времени (из switch.json, живые данные).
func (c *core) trialState() map[string]any {
	if ptr, err := config.ReadPointers(c.p); err == nil && ptr.Switch != nil {
		return map[string]any{"active": true, "deadline": ptr.Switch.Deadline.Format(time.RFC3339), "clock": ptr.Switch.Deadline.Format("15:04:05")}
	}
	return map[string]any{"active": false}
}

func (c *core) publishTrial() { c.publish("trial", c.trialState()) }

// noteTrialFailure — запомнить причину неудачи для страницы и отката (переживает перезапуск ядра).
func (c *core) noteTrialFailure(reason string) {
	config.NoteTrialFailure(c.p, c.gen, sanitize(reason))
}

// publishReady — «конфиг принят»; если только что был откат, остаётся его причина, а не «принят».
func (c *core) publishReady(text string) {
	if rb, ok := config.ReadRollback(c.p); ok {
		c.publishApply("rolledback", "Изменение отменено: "+sanitize(rb.Reason))
	} else {
		c.publishApply("ready", text)
	}
	c.publishTrial()
}

func (c *core) publishApply(stage, text string) {
	m := map[string]any{"stage": stage, "text": text, "at": time.Now().Format("15:04:05")}
	c.ev.mu.Lock()
	c.ev.apply = m
	c.ev.mu.Unlock()
	c.publish("apply", m)
}

// publishUpdate — стадия обновления/отката версии: checking | downloading | verifying | restarting | ready |
// uptodate | rolledback | error.
func (c *core) publishUpdate(stage, text string) {
	m := map[string]any{"stage": stage, "text": text, "at": time.Now().Format("15:04:05")}
	c.ev.mu.Lock()
	c.ev.update = m
	c.ev.mu.Unlock()
	c.publish("update", m)
}

const updatingFile = "updating.json" // в State: версия, на которую только что обновились (до подтверждения good)

type updatingMark struct {
	Version string `json:"version"`
	From    string `json:"from"`
}

func (c *core) markUpdating(version string) {
	b, _ := json.Marshal(updatingMark{Version: version, From: c.f.Version})
	_ = os.WriteFile(filepath.Join(c.p.State, updatingFile), append(b, '\n'), 0600)
}

// loadUpdating (при старте ядра): если после обновления запустилась не та версия — сторож откатил её; сказать об этом.
func (c *core) loadUpdating() {
	b, err := os.ReadFile(filepath.Join(c.p.State, updatingFile))
	if err != nil {
		return
	}
	var m updatingMark
	if json.Unmarshal(b, &m) != nil || m.Version == "" {
		_ = os.Remove(filepath.Join(c.p.State, updatingFile))
		return
	}
	if m.Version == c.f.Version {
		c.freshFrom = m.From
		c.publishUpdate("restarting", "Запущена версия "+m.Version+", проверяю запуск...")
		return
	}
	_ = os.Remove(filepath.Join(c.p.State, updatingFile))
	why := sanitize(c.f.RollbackReason)
	if why == "" {
		why = "причина не передана"
	}
	c.publishUpdate("rolledback", "Версия "+m.Version+" не заработала ("+why+"), возвращена версия "+c.f.Version+".")
}

// confirmUpdate (после good): обновление подтверждено.
func (c *core) confirmUpdate() {
	b, err := os.ReadFile(filepath.Join(c.p.State, updatingFile))
	if err != nil {
		return
	}
	var m updatingMark
	_ = json.Unmarshal(b, &m)
	_ = os.Remove(filepath.Join(c.p.State, updatingFile))
	if m.Version == c.f.Version {
		c.publishUpdate("ready", "Версия "+c.f.Version+" работает (обновлено с "+m.From+").")
	}
}

// snapshot — ТЕКУЩЕЕ состояние каждого вида из живых данных (а не последнее опубликованное): его получает
// страница при подключении к /api/events.
func (c *core) snapshot() map[string]any {
	out := map[string]any{"status": c.Status(), "trial": c.trialState()}
	c.ev.mu.Lock()
	if c.ev.apply != nil {
		out["apply"] = c.ev.apply
	}
	if c.ev.paths != nil {
		out["paths"] = c.ev.paths
	}
	if c.ev.update != nil {
		out["update"] = c.ev.update
	}
	if len(c.ev.attempts) > 0 {
		out["attempts"] = append([]attempt(nil), c.ev.attempts...)
	}
	c.ev.mu.Unlock()
	if ch := c.getCh(); ch != nil {
		st := ch.State()
		out["channel"] = map[string]any{"state": st.State, "path": st.Path, "reason": sanitize(st.Reason), "session": st.Session}
	}
	if sb := c.getSb(); !isNil(sb) {
		st := sb.Status()
		if e, ok := st["binaryError"].(string); ok {
			st["binaryError"] = sanitize(e)
		}
		delete(st, "chan")
		out["singbox"] = st
	}
	return out
}

func (c *core) publishSingbox() {
	sb := c.getSb()
	if isNil(sb) {
		return
	}
	st := sb.Status()
	if e, ok := st["binaryError"].(string); ok {
		st["binaryError"] = sanitize(e)
	}
	delete(st, "chan")
	c.publish("singbox", st)
}

// onChannelState — запись попытки подключения и обновление страницы; только по событию канала.
func (c *core) onChannelState(st api.ChannelState) {
	a := attempt{At: time.Now().Format("15:04:05"), Path: st.Path}
	switch st.State {
	case "connecting":
		a.State = "trying"
	case "up":
		a.State = "ok"
	case "down":
		a.State, a.Reason = "error", sanitize(st.Reason)
	default:
		a.State, a.Reason = "waiting", sanitize(st.Reason)
	}
	c.ev.mu.Lock()
	c.ev.n++
	a.N = c.ev.n
	c.ev.attempts = append(c.ev.attempts, a)
	if len(c.ev.attempts) > 30 {
		c.ev.attempts = c.ev.attempts[len(c.ev.attempts)-30:]
	}
	list := append([]attempt(nil), c.ev.attempts...)
	c.ev.mu.Unlock()
	c.publish("channel", map[string]any{"state": st.State, "path": st.Path, "reason": sanitize(st.Reason), "session": st.Session})
	c.publish("attempts", list)
	c.publishStatus()
	select {
	case c.ev.kick <- struct{}{}:
	default:
	}
}

// pathsLoop — по событию канала/sing-box спрашивает у sing-box состояние узлов (последний замер) и шлёт на страницу.
func (c *core) pathsLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.ev.kick:
			c.publishPaths(ctx)
		}
	}
}

func (c *core) publishPaths(ctx context.Context) {
	sb := c.getSb()
	if isNil(sb) {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	namesCh := make(chan []string, 1)
	go func() { namesCh <- sb.PathNames() }() // PathNames может ждать запуск sing-box
	var names []string
	select {
	case names = <-namesCh:
	case <-ctx.Done():
		return
	}
	type node struct {
		Name  string `json:"name"`
		State string `json:"state"` // ok | error | unknown
		MS    int    `json:"ms,omitempty"`
	}
	var nodes []node
	for _, n := range names {
		var out struct {
			History []struct {
				Delay int `json:"delay"`
			} `json:"history"`
		}
		nd := node{Name: sanitize(n), State: "unknown"}
		if err := sb.Clash(ctx, "GET", "/proxies/"+url.PathEscape(n), nil, &out); err == nil && len(out.History) > 0 {
			d := out.History[len(out.History)-1].Delay
			if d > 0 {
				nd.State, nd.MS = "ok", d
			} else {
				nd.State = "error"
			}
		}
		nodes = append(nodes, nd)
	}
	now := ""
	var grp struct {
		Now string `json:"now"`
	}
	if err := sb.Clash(ctx, "GET", "/proxies/chan", nil, &grp); err == nil {
		now = sanitize(grp.Now)
	}
	pm := map[string]any{"nodes": nodes, "now": now}
	c.ev.mu.Lock()
	c.ev.paths = pm
	c.ev.mu.Unlock()
	c.publish("paths", pm)
}

// publishStartInfo — что страница должна знать сразу после (пере)запуска ядра: идёт ли проверка нового конфига,
// осталась ли ошибка прошлой попытки (например, откат из-за недопустимого имени).
func (c *core) publishStartInfo() {
	c.errMu.Lock()
	le := c.lastErr
	c.errMu.Unlock()
	c.publishTrial()
	if ptr, err := config.ReadPointers(c.p); err == nil && ptr.Switch == nil {
		if rb, ok := config.ReadRollback(c.p); ok {
			c.publishApply("rolledback", "Изменение отменено: "+sanitize(rb.Reason))
			return
		}
	}
	if ptr, err := config.ReadPointers(c.p); err == nil && ptr.Switch != nil && ptr.Switch.To == c.gen && c.gen != "" {
		left := max(int(time.Until(ptr.Switch.Deadline).Seconds()), 0)
		c.publishApply("checking", fmt.Sprintf("Проверяю связь с сервером по новому конфигу (до %d с, потом откат).", left))
		return
	}
	if le != "" && !c.upOnce.Load() {
		c.publishApply("error", le)
	}
}
