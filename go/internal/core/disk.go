package core

import (
	"context"
	"encoding/json"
	"runtime"

	"remoteagents/internal/disk"
	"remoteagents/internal/singbox"
)

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
	if runtime.GOOS != "windows" {
		c.launchDisk(ctx, dcfg, "", nil, "Диск работает только на Windows")
		return
	}
	go func() {
		bin, err := singbox.InstallSyncthing(ctx, c.p, c.log, c.clean)
		if err != nil {
			c.log.Warn("core: disk-binary", "err", err.Error())
			c.launchDisk(ctx, dcfg, "", nil, err.Error())
			return
		}
		c.launchDisk(ctx, dcfg, bin, []string{"syncthing"}, "")
	}()
}

func (c *core) launchDisk(ctx context.Context, dcfg disk.Config, bin string, args []string, why string) {
	ch := c.getCh()
	if ch == nil {
		return
	}
	eng := disk.New(disk.Deps{
		Cfg: dcfg, Channel: ch, ChannelJSON: c.cfg.Paths.Channel, Procs: c.pr, Log: c.log, Paths: c.p,
		Bin: bin, BinArgs: args, BinWhy: why,
		OnState: func(s disk.Snapshot) { c.publish("disk", s.Map()); c.publishStatus() },
	})
	c.compMu.Lock()
	c.dsk = eng
	c.compMu.Unlock()
	if err := eng.Start(ctx); err != nil {
		c.log.Error("core: disk-start", "err", err.Error())
	}
}
