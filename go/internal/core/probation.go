package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"remoteagents/internal/config"
)

// Правило «новая версия хорошая» (см. docs/update-test.md, «Критерий good»):
//   - good (сторожу) = ядро стартовало, конфиг прочитан или отвергнут проверкой, страница отвечает.
//     Связь с сервером и конфиг на good не влияют; применение конфига в окне версию не откатывает.
//   - Если после обновления канал не поднялся за probationWait, версию откатываем только когда со старой версией
//     на том же поколении конфига канал работал (chanok.json), а с новой нет. Иначе версия остаётся.
const (
	chanOKFile    = "chanok.json" // в State: версия и поколение конфига, с которыми канал последний раз поднимался
	probationWait = 120 * time.Second
)

type chanOK struct {
	Version string `json:"version"`
	Gen     string `json:"gen"`
}

func (c *core) readChanOK() (chanOK, bool) {
	var m chanOK
	b, err := os.ReadFile(filepath.Join(c.p.State, chanOKFile))
	if err != nil || json.Unmarshal(b, &m) != nil || m.Version == "" {
		return m, false
	}
	return m, true
}

// recordChannelOK — канал поднялся: запомнить (версия, поколение конфига).
func (c *core) recordChannelOK() {
	b, _ := json.Marshal(chanOK{Version: c.f.Version, Gen: c.gen})
	_ = os.WriteFile(filepath.Join(c.p.State, chanOKFile), append(b, '\n'), 0600)
	if c.freshFrom != "" {
		c.decide("kept", "Версия "+c.f.Version+" оставлена: связь с сервером установлена.")
	}
}

// decide — решение по версии: в журнал и на страницу.
func (c *core) decide(kind, text string) {
	c.log.Info("core: version-decision", "kind", kind, "version", c.f.Version, "text", text)
	stage := "ready"
	if kind == "rollback" {
		stage = "restarting"
	}
	c.publishUpdate(stage, text)
}

// startProbation — после обновления ждёт канал probationWait и решает, оставлять ли версию.
func (c *core) startProbation(ctx context.Context) {
	if c.freshFrom == "" || c.cfg == nil || c.f.Mode.NoChannel {
		return
	}
	go func() {
		t := time.NewTimer(probationWait)
		defer t.Stop()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if c.upOnce.Load() {
			return
		}
		if ptr, err := config.ReadPointers(c.p); err == nil && ptr.Switch != nil {
			c.decide("kept", "Версия "+c.f.Version+" оставлена: идёт проверка нового конфига, это не вина версии.")
			return
		}
		ok, has := c.readChanOK()
		switch {
		case !has:
			c.decide("kept", "Версия "+c.f.Version+" оставлена: связи нет, но прежде она с этим конфигом не работала (нечего сравнивать).")
		case ok.Gen != c.gen:
			c.decide("kept", "Версия "+c.f.Version+" оставлена: связь работала на другом конфиге, сравнивать нельзя.")
		case ok.Version == c.f.Version:
			c.decide("kept", "Версия "+c.f.Version+" оставлена: связь пропала, но с этой же версией раньше работала (не вина обновления).")
		default:
			c.decide("rollback", "Связи с сервером нет, а версия "+ok.Version+" с этим конфигом работала: возвращаю её.")
			if err := c.Rollback(ctx, "channel did not come up; "+ok.Version+" worked on the same config"); err != nil {
				c.log.Warn("core: probation-rollback", "err", err.Error())
			}
		}
	}()
}
