package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"

	"remoteagents/internal/api"
	"remoteagents/internal/disk"
)

// diskBinary — syncthing рядом с программой: bin/syncthing(.exe), иначе bin/syncthingtray(.exe) с аргументом "syncthing".
func diskBinary(p api.Paths) (string, []string) {
	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}
	if b := filepath.Join(p.Bin, "syncthing"+ext); fileExists(b) {
		return b, nil
	}
	if b := filepath.Join(p.Bin, "syncthingtray"+ext); fileExists(b) {
		return b, []string{"syncthing"}
	}
	return "", nil
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func (c *core) getDisk() *disk.Engine {
	c.compMu.RLock()
	defer c.compMu.RUnlock()
	return c.dsk
}

// startDisk — шаг 9: Диск поверх канала (не в Safe и не без канала).
func (c *core) startDisk(ctx context.Context) {
	ch := c.getCh()
	if ch == nil || c.f.Mode.Safe {
		return
	}
	var top int
	var raw struct {
		SyncPort int `json:"syncPort"`
	}
	if json.Unmarshal(c.cfg.Raw, &raw) == nil {
		top = raw.SyncPort
	}
	dcfg, err := disk.ParseConfig(c.cfg.Disk, top)
	if err != nil {
		c.log.Error("core: disk-config", "err", err.Error())
		return
	}
	bin, args := diskBinary(c.p)
	eng := disk.New(disk.Deps{
		Cfg: dcfg, Channel: ch, ChannelJSON: c.cfg.Paths.Channel, Procs: c.pr, Log: c.log, Paths: c.p,
		Bin: bin, BinArgs: args,
		OnState: func(s disk.Snapshot) { c.publish("disk", s.Map()); c.publishStatus() },
	})
	c.compMu.Lock()
	c.dsk = eng
	c.compMu.Unlock()
	if err := eng.Start(ctx); err != nil {
		c.log.Error("core: disk-start", "err", err.Error())
	}
}
