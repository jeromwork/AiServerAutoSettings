package explorer

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// Deps — зависимости контроллера Проводника.
type Deps struct {
	DiskHome string                    // каталог Диска (Home)
	ProgHome string                    // --home программы для команд меню; пусто — не передавать
	Exe      string                    // путь программы для команд меню
	Root     func() string             // база Диска
	NewAPI   func() (FolderAPI, error) // открыть REST (ошибка — Диск пока недоступен)
	Rules    string                    // обязательные исключения
	Meta     *Service
	Reg      *Registry
	Recycle  func(string) error
	Log      func(string)
}

// Controller держит оформление Проводника в согласии с Диском. Без таймеров: ждёт события Syncthing
// (long-poll) или сигнал Wake от ядра (Диск перешёл в «работает»).
type Controller struct {
	d      Deps
	gate   sync.Mutex // команды и обновление оформления — по одному
	wake   chan struct{}
	cancel context.CancelFunc
	done   chan struct{}

	mu       sync.Mutex
	api      FolderAPI
	last     *Snapshot
	lastRoot string
}

func NewController(d Deps) *Controller {
	if d.Log == nil {
		d.Log = func(string) {}
	}
	return &Controller{d: d, wake: make(chan struct{}, 1)}
}

// Start запускает наблюдение.
func (c *Controller) Start(ctx context.Context) {
	ctx, c.cancel = context.WithCancel(ctx)
	c.done = make(chan struct{})
	go c.loop(ctx)
}

// Wake — состояние Диска изменилось: переподключиться к Syncthing.
func (c *Controller) Wake() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// Stop снимает меню, ставит значкам «недоступно» и останавливает наблюдение.
func (c *Controller) Stop() {
	if c.cancel == nil {
		return
	}
	c.cancel()
	<-c.done
	c.gate.Lock()
	defer c.gate.Unlock()
	c.d.Reg.Cleanup()
	c.markUnavailable()
}

func (c *Controller) setAPI(a FolderAPI) { c.mu.Lock(); c.api = a; c.mu.Unlock() }
func (c *Controller) getAPI() FolderAPI  { c.mu.Lock(); defer c.mu.Unlock(); return c.api }

func (c *Controller) loop(ctx context.Context) {
	defer close(c.done)
	for ctx.Err() == nil {
		c.session(ctx)
		c.setAPI(nil)
		select {
		case <-ctx.Done():
			return
		case <-c.wake:
		}
	}
}

// session работает, пока Syncthing отвечает; возврат — он недоступен (ждём Wake).
func (c *Controller) session(ctx context.Context) {
	api, err := c.d.NewAPI()
	if err != nil {
		c.unavailable()
		return
	}
	c.setAPI(api)
	if err := c.refresh(ctx, api); err != nil {
		c.d.Log("disk.explorer.unavailable")
		c.unavailable()
		return
	}
	since := tailEvent(ctx, api)
	for ctx.Err() == nil {
		evs, next, err := events(ctx, api, since, 25)
		if err != nil {
			if ctx.Err() == nil {
				c.d.Log("disk.explorer.unavailable")
				c.unavailable()
			}
			return
		}
		gap := since > 0 && len(evs) > 0 && int64(num(mp(evs[0]), "id")) > since+1
		since = next
		if len(evs) == 0 && !gap {
			// Таймаут long-poll: заглушку могли убрать из Проводника без события Syncthing.
			c.gate.Lock()
			if c.last != nil && samePath(c.lastRoot, c.d.Root()) {
				c.publish(c.d.Root(), c.last)
			}
			c.gate.Unlock()
			continue
		}
		if err := c.refresh(ctx, api); err != nil {
			if ctx.Err() == nil {
				c.unavailable()
			}
			return
		}
	}
}

func (c *Controller) commands(api FolderAPI) *Commands {
	return &Commands{API: api, Root: c.d.Root(), Meta: c.d.Meta, Rules: c.d.Rules, Recycle: c.d.Recycle, DiskHome: c.d.DiskHome, Log: c.d.Log}
}

func (c *Controller) refresh(ctx context.Context, api FolderAPI) error {
	c.gate.Lock()
	defer c.gate.Unlock()
	snap, err := c.commands(api).Read(ctx)
	if err != nil {
		return err
	}
	c.publish(c.d.Root(), snap)
	return nil
}

// Submit выполняет команду меню и обновляет оформление.
func (c *Controller) Submit(ctx context.Context, action, path string) (string, error) {
	api := c.getAPI()
	if api == nil {
		return "", errors.New("Диск ещё не готов. Подождите немного и повторите")
	}
	c.gate.Lock()
	defer c.gate.Unlock()
	cmd := c.commands(api)
	msg, err := cmd.Execute(ctx, action, path)
	if err != nil {
		c.d.Log("disk.shell." + action + ".failed")
		return "", err
	}
	c.d.Log("disk.shell." + action + ".ok")
	if snap, e := cmd.Read(ctx); e == nil {
		c.publish(c.d.Root(), snap)
	} else {
		c.d.Log("disk.explorer.refresh.failed")
	}
	return msg, nil
}

func (c *Controller) manifest() string { return filepath.Join(c.d.DiskHome, "explorer-folders.json") }

// publish применяет снимок: значки, меню, манифест. Под c.gate.
func (c *Controller) publish(root string, snap *Snapshot) {
	if c.lastRoot != "" && !samePath(root, c.lastRoot) {
		c.clear()
	}
	var paths []string
	keep := map[string]bool{}
	for _, f := range snap.Folders {
		if f.Kind != KindLocal {
			paths = append(paths, f.Path)
			keep[lowerPath(f.Path)] = true
		}
	}
	for _, old := range readManifest(c.manifest()) {
		if !keep[lowerPath(old)] {
			c.d.Meta.CleanupFolder(old, true)
		}
	}
	c.d.Meta.Reconcile(root, snap.Folders)
	var menu []*FolderState
	for _, f := range snap.Folders {
		if !f.ServerOnly || f.Kind == KindLocalCopy || c.d.Meta.IsPlaceholder(f.Path) {
			menu = append(menu, f)
		}
	}
	icon, err := c.d.Meta.ApplicationIcon()
	if err != nil {
		c.d.Log("disk.explorer.icon.failed")
	}
	if err := c.d.Reg.Register(c.d.Exe, root, menu, c.d.ProgHome, icon); err != nil {
		c.d.Log("disk.explorer.menu.failed")
	}
	writeManifest(c.manifest(), paths)
	c.last, c.lastRoot = snap, root
}

func (c *Controller) clear() {
	c.d.Reg.Cleanup()
	if c.last != nil {
		for _, f := range c.last.Folders {
			c.d.Meta.CleanupFolder(f.Path, true)
		}
	}
	c.last, c.lastRoot = nil, ""
}

func (c *Controller) unavailable() {
	c.gate.Lock()
	defer c.gate.Unlock()
	c.markUnavailable()
}

// markUnavailable: известные папки получают значок «недоступно» (заглушки остаются заглушками); меню снимается,
// потому что команды без Диска не выполнить. Под c.gate.
func (c *Controller) markUnavailable() {
	root := c.lastRoot
	if c.last == nil {
		root = c.d.Root()
		c.last = &Snapshot{}
		for _, p := range readManifest(c.manifest()) {
			ph := c.d.Meta.IsPlaceholder(p)
			k := KindUnavailable
			if ph {
				k = KindServerOnly
			}
			c.last.Folders = append(c.last.Folders, &FolderState{Path: p, ServerOnly: ph, Kind: k})
		}
	}
	rows := make([]*FolderState, 0, len(c.last.Folders))
	for _, f := range c.last.Folders {
		cp := *f
		if !cp.ServerOnly && cp.Kind != KindLocal && cp.Kind != KindServerRemoved {
			cp.Kind = KindUnavailable
		}
		rows = append(rows, &cp)
	}
	c.d.Reg.Cleanup()
	c.d.Meta.Reconcile(root, rows)
	c.lastRoot = root
}

// RemoveIntegration полностью убирает оформление (Диск выключен/удаляется).
func RemoveIntegration(root, diskHome string, meta *Service, reg *Registry) {
	reg.Cleanup()
	meta.Cleanup(root, true)
	m := filepath.Join(diskHome, "explorer-folders.json")
	for _, p := range readManifest(m) {
		meta.CleanupFolder(p, true)
	}
	_ = os.Remove(m)
}
