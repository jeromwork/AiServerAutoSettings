package core

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"

	"remoteagents/internal/disk"
	"remoteagents/internal/disk/explorer"
)

// startExplorer — значки и меню Проводника для Диска (только Windows). Меню ставится вместе с Диском и снимается при его остановке.
func (c *core) startExplorer(ctx context.Context, dcfg disk.Config) *explorer.Controller {
	if runtime.GOOS != "windows" || !dcfg.On() {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return nil
	}
	diskHome := dcfg.Home
	if diskHome == "" {
		diskHome = disk.DefaultHome(c.p.Home)
	}
	root := disk.BaseDir(dcfg.Base)
	log := func(s string) { c.log.Info("core: " + s) }
	meta := explorer.NewService(explorer.OSFS{}, explorer.IconDir{Dir: filepath.Join(diskHome, "explorer-icons")}, explorer.NewNotifier(), log)
	reg := explorer.NewRegistry(explorer.NewRegStore(), log, explorer.AssociationsChanged)
	ctl := explorer.NewController(explorer.Deps{
		DiskHome: diskHome, ProgHome: c.p.Home, Exe: exe, Root: func() string { return root },
		NewAPI: func() (explorer.FolderAPI, error) { return explorer.NewAPI(diskHome) },
		Rules:  disk.IgnoreRules(), Meta: meta, Reg: reg, Recycle: explorer.RecycleBin, Log: log,
	})
	ctl.Start(ctx)
	return ctl
}

func (c *core) getExplorer() *explorer.Controller {
	c.compMu.RLock()
	defer c.compMu.RUnlock()
	return c.dex
}

// DiskShell выполняет команду меню Проводника (webui /api/disk/shell ← `remoteagents disk-shell`).
func (c *core) DiskShell(ctx context.Context, cmd, path string) (string, error) {
	ex := c.getExplorer()
	if ex == nil {
		return "", errors.New("Диск не работает на этом компьютере")
	}
	return ex.Submit(ctx, cmd, path)
}
