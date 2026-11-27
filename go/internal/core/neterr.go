package core

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/config"
	"remoteagents/internal/webui"
)

const lastErrFile = "lasterr.txt"

// fatalChannelReason — причины обрыва канала, которые ожиданием не пройдут.
func fatalChannelReason(r string) bool {
	return strings.Contains(r, "host key mismatch") || strings.Contains(r, "unable to authenticate")
}

// explainNetErr — понятный русский текст по ошибке запуска сети.
func explainNetErr(err error) string {
	e := err.Error()
	has := func(subs ...string) bool {
		for _, s := range subs {
			if strings.Contains(e, s) {
				return true
			}
		}
		return false
	}
	switch {
	case has("bad-pc-name"):
		return "Недопустимое имя компьютера для сервера (нужны латиница, цифры, . _ -). Задайте его параметром --pc."
	case has("bad-key"):
		return "В конфиге неверный ключ доступа к серверу."
	case has("hostkey-missing", "hostkey-invalid"):
		return "В конфиге нет верного отпечатка сервера (hostKey)."
	case has("host key mismatch"):
		return "Отпечаток сервера не совпал с конфигом: возможна подмена или конфиг устарел."
	case has("unable to authenticate"):
		return "Сервер не принял ключ из конфига."
	case has("no-server"):
		return "В конфиге не указан сервер."
	case has("singbox: lock", "singbox: binary", "executable file not found", "no such file"):
		return "Не найден или не создан sing-box (нужен для канала)."
	case has("singbox: config", "singbox: check", "singbox: port"):
		return "Конфиг sing-box не принят: проверьте маршруты в конфиге."
	case has("singbox:"):
		return "Не запустился sing-box: " + e
	}
	return "Не удалось запустить связь с сервером: " + e
}

// failStart — ошибка, которая не пройдёт ожиданием: на страницу и, если шло применение конфига, откат сразу.
func (c *core) failStart(err error) {
	if c.upOnce.Load() {
		return
	}
	text := explainNetErr(err)
	if c.cfg.HasChannel() && c.pcName() == "" {
		text = "В конфиге нет имени компьютера латиницей."
	}
	text = sanitize(text)
	c.log.Error("core: net-fatal", "text", text, "err", err.Error())
	c.errMu.Lock()
	c.lastErr = text
	c.errMu.Unlock()
	c.publishApply("error", text)
	c.publishStatus()
	// Версия сама жива: сетевая ошибка конфига/порта лечится откатом конфига, а не слотом версии (сторож).
	c.sendGood()
	_ = os.WriteFile(filepath.Join(c.p.State, lastErrFile), []byte(text+"\n"), 0600)
	ptr, perr := config.ReadPointers(c.p)
	if perr != nil || ptr.Switch == nil || ptr.Switch.To != c.gen {
		return
	}
	c.failed.Store(true)
	unlock, lerr := c.lockOp()
	if lerr != nil {
		return
	}
	defer unlock()
	if rerr := config.Revert(c.p, c.log); rerr != nil {
		c.log.Warn("core: fast-revert", "err", rerr.Error())
		return
	}
	c.log.Warn("core: fast-revert", "text", text)
	c.requestQuit(api.ExitRestart, nil)
}

func (c *core) loadLastErr() {
	b, err := os.ReadFile(filepath.Join(c.p.State, lastErrFile))
	if err != nil {
		return
	}
	c.errMu.Lock()
	c.lastErr = strings.TrimSpace(string(b))
	c.errMu.Unlock()
}

func (c *core) clearLastErr() {
	c.errMu.Lock()
	c.lastErr = ""
	c.errMu.Unlock()
	_ = os.Remove(filepath.Join(c.p.State, lastErrFile))
}

// connectInfo — для страницы: идёт ли ожидание первого up (после «Применить»), сколько осталось, последняя ошибка.
func (c *core) connectInfo() map[string]any {
	c.errMu.Lock()
	m := map[string]any{"error": c.lastErr}
	c.errMu.Unlock()
	pending := false
	if ch := c.getCh(); ch != nil && !c.failed.Load() && !c.upOnce.Load() && c.gen != "" {
		if ptr, err := config.ReadPointers(c.p); err == nil && ptr.Switch != nil && ptr.Switch.To == c.gen {
			pending = true
			m["left"] = max(int(time.Until(ptr.Switch.Deadline).Seconds()), 0)
			if s := ch.State(); s.Reason != "" {
				m["reason"] = sanitize(s.Reason)
			}
		}
	}
	if pending {
		m["error"] = "" // идёт новая попытка: старая ошибка не показывается как текущая
	}
	m["pending"] = pending
	return m
}

// uiPrevFile — порт и токен страницы; в отличие от webui.url не удаляется при выходе.
const uiPrevFile = "webui.prev"

func (c *core) prevUI() webui.Prev {
	b, err := os.ReadFile(filepath.Join(c.p.State, uiPrevFile))
	if err != nil {
		return webui.Prev{}
	}
	f := strings.Fields(string(b))
	if len(f) != 2 {
		return webui.Prev{}
	}
	n, _ := strconv.Atoi(f[0])
	return webui.Prev{Port: n, Token: f[1]}
}

func (c *core) savePrevUI() {
	_ = os.WriteFile(filepath.Join(c.p.State, uiPrevFile), []byte(strconv.Itoa(c.ui.Port())+" "+c.ui.Token()+"\n"), 0600)
}
