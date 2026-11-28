package explorer

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Commands выполняет команды меню Проводника через FolderAPI.
type Commands struct {
	API          FolderAPI
	Root         string // база Диска
	Meta         *Service
	Rules        string             // обязательные исключения (.stignore-remoteagents)
	Recycle      func(string) error // в Корзину; без запасного удаления навсегда
	ReadyTimeout time.Duration      // сколько ждать подтверждения сервером перед «Оставить только на сервере» (по умолчанию 30 с)
	DiskHome     string             // для памяти подтверждённых папок
	Log          func(string)
}

func (c *Commands) timeout() time.Duration {
	if c.ReadyTimeout > 0 {
		return c.ReadyTimeout
	}
	return 30 * time.Second
}

// Read — текущие папки с различением заглушек и локальных копий.
func (c *Commands) Read(ctx context.Context) (*Snapshot, error) {
	snap, err := ReadSnapshot(ctx, c.API, c.Root, c.DiskHome)
	if err != nil {
		return nil, err
	}
	c.Meta.ClassifyLocalCopies(snap.Folders)
	return snap, nil
}

// plainPath — путь и его родители не ссылки.
func (c *Commands) plainPath(p string) error {
	if c.Meta.hasReparseAncestor(p) {
		return errors.New("Папка или её родитель является ссылкой")
	}
	return nil
}

func (c *Commands) location(p string) error {
	if samePath(p, c.Root) || !isChild(p, c.Root) {
		return errors.New("Подключать можно только папки непосредственно внутри базы Диска; внешние и вложенные пути не поддерживаются")
	}
	return nil
}

func (c *Commands) available(p string, others []*FolderState) error {
	if err := c.plainPath(p); err != nil {
		return err
	}
	if err := c.location(p); err != nil {
		return err
	}
	if samePath(p, c.Root) || within(c.Root, p) || samePath(p, filepath.VolumeName(p)+string(filepath.Separator)) {
		return errors.New("Нельзя подключить корень диска или родителя Disk")
	}
	if c.Meta.isFile(p) {
		return errors.New("Путь занят файлом")
	}
	for _, f := range others {
		if !f.ServerOnly && overlaps(p, f.Path) {
			return errors.New("Путь пересекается с папкой Syncthing")
		}
	}
	return nil
}

// Execute выполняет команду над папкой path и возвращает сообщение для владельца.
func (c *Commands) Execute(ctx context.Context, action, path string) (string, error) {
	if !ValidCommand(action) {
		return "", errors.New("Неизвестная команда Диска")
	}
	path, err := cleanPath(path)
	if err != nil {
		return "", err
	}
	if err := c.plainPath(path); err != nil {
		return "", err
	}
	if err := c.location(path); err != nil {
		return "", err
	}
	snap, err := c.Read(ctx)
	if err != nil {
		return "", err
	}
	var matches []*FolderState
	for _, f := range snap.Folders {
		if samePath(f.Path, path) {
			matches = append(matches, f)
		}
	}
	if len(matches) > 1 {
		return "", errors.New("Имя занято на сервере: путь соответствует нескольким папкам Syncthing")
	}
	var row *FolderState
	if len(matches) == 1 {
		row = matches[0]
	}
	if row != nil && row.Kind == KindServerRemoved {
		return "", errors.New("Папка удалена на сервере. Локальная копия отсоединена и сохранена")
	}
	switch action {
	case CmdKeepServer:
		if row == nil || row.ServerOnly || row.Config == nil || row.Kind != KindSynced || !ValidName(row.Name) {
			return "", errors.New("Сначала дождитесь подтверждённой синхронизации папки с сервером")
		}
		if err := c.keep(ctx, row); err != nil {
			return "", err
		}
		return "Локальные файлы в Корзине. Папка оставлена только на сервере", nil
	case CmdSync:
		if row == nil || !row.ServerOnly || row.Kind != KindLocalCopy || !c.Meta.isDir(path) {
			return "", errors.New("Нужна локальная копия предложенной сервером папки")
		}
		if err := c.accept(ctx, row, snap); err != nil {
			return "", err
		}
		return "Локальная копия подключена к серверу. Слияние и синхронизация запущены", nil
	case CmdDownload:
		if row == nil || !row.ServerOnly || row.Kind != KindServerOnly || !c.Meta.IsPlaceholder(path) {
			return "", errors.New("Нужна пустая заглушка предложенной сервером папки")
		}
		if err := c.accept(ctx, row, snap); err != nil {
			return "", err
		}
		return "Папка скачивается на компьютер. Синхронизация запущена", nil
	}
	return c.add(ctx, row, snap, path)
}

func (c *Commands) add(ctx context.Context, row *FolderState, snap *Snapshot, path string) (string, error) {
	if !c.Meta.isDir(path) {
		return "", errors.New("Папка не найдена")
	}
	peer := c.API.Peer()
	if row != nil && !row.ServerOnly {
		if row.Kind == KindLocal {
			return "", errors.New("Регистрация не предложена сервером; снимите её в Syncthing перед явной новой загрузкой")
		}
		if row.Uploads() {
			if row.Kind == KindPending || row.Kind == KindOffline {
				return "Папка предложена серверу. Ожидает сервер", nil
			}
			return "Папка уже синхронизируется с сервером", nil
		}
		if !ValidName(row.Name) || nameTaken(snap, row.Name, row) {
			return "", errors.New("Имя папки уже занято или недопустимо на сервере")
		}
		// Открываем уже общую регистрацию на отправку, не заменяя остальные её настройки.
		devices := arr(row.Config["devices"])
		found := false
		for _, d := range devices {
			found = found || str(mp(d), "deviceID") == peer
		}
		if !found {
			devices = append(devices, map[string]any{"deviceID": peer})
		}
		rules, err := NewIgnoreChange(row.Path, c.Rules)
		if err != nil {
			return "", err
		}
		_, err = call(ctx, c.API, "PATCH", "config/folders/"+esc(row.ID), map[string]any{"devices": devices, "type": "sendreceive"})
		rules.Commit() // потерянный ответ не должен снимать исключения с уже общего источника
		if err != nil {
			return "", err
		}
		return "Папка предложена серверу. Ожидает сервер", nil
	}
	name := filepath.Base(path)
	if !ValidName(name) {
		return "", errors.New("Имя папки недопустимо на сервере")
	}
	if nameTaken(snap, name, nil) {
		return "", fmt.Errorf("Имя занято на сервере; используйте «%s»", MenuDownload)
	}
	// Сервер берёт метку как имя папки верхнего уровня; ID не должен совпасть локально.
	id := uploadID(path)
	for _, f := range snap.Folders {
		if strings.EqualFold(f.ID, id) {
			return "", errors.New("ID папки уже занят в Syncthing")
		}
	}
	nr := &FolderState{ID: id, Name: name, Path: path}
	if err := c.accept(ctx, nr, snap); err != nil {
		return "", err
	}
	return "Папка предложена серверу. Ожидает сервер", nil
}

func nameTaken(snap *Snapshot, name string, except *FolderState) bool {
	for _, f := range snap.Folders {
		if f != except && strings.EqualFold(f.Name, name) {
			return true
		}
	}
	return false
}

// uploadID — стабильный ID новой папки: «ra-» + имя в нижнем регистре и 8 знаков хеша пути.
func uploadID(path string) string {
	h := uint32(2166136261)
	for _, b := range []byte(strings.ToLower(path)) {
		h = (h ^ uint32(b)) * 16777619
	}
	var sb strings.Builder
	for _, r := range strings.ToLower(filepath.Base(path)) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			sb.WriteRune(r)
		} else {
			sb.WriteByte('-')
		}
	}
	return fmt.Sprintf("ra-%s-%08x", sb.String(), h)
}

// accept регистрирует папку в Syncthing как send+receive с сервером (слияние существующих файлов делает Syncthing).
func (c *Commands) accept(ctx context.Context, row *FolderState, snap *Snapshot) error {
	if err := c.available(row.Path, snap.Folders); err != nil {
		return err
	}
	defv, err := call(ctx, c.API, "GET", "config/defaults/folder", nil)
	if err != nil {
		return err
	}
	st, err := call(ctx, c.API, "GET", "system/status", nil)
	if err != nil {
		return err
	}
	localID := str(mp(st), "myID")
	if localID == "" {
		return errors.New("Syncthing не сообщил ID компьютера")
	}
	cfg := mp(defv)
	cfg["id"], cfg["label"], cfg["path"], cfg["type"] = row.ID, row.Name, row.Path, "sendreceive"
	cfg["paused"], cfg["fsWatcherEnabled"], cfg["fsWatcherDelayS"], cfg["maxConflicts"] = false, true, 2, -1
	cfg["versioning"] = map[string]any{"type": "staggered", "params": map[string]any{"maxAge": "2592000", "cleanInterval": "3600"}}
	cfg["devices"] = []any{map[string]any{"deviceID": localID}, map[string]any{"deviceID": c.API.Peer()}}
	// Исключения ставим до регистрации: первое сканирование не должно отправить .git и секреты.
	rules, err := NewIgnoreChange(row.Path, c.Rules)
	if err != nil {
		return err
	}
	defer rules.Close()
	if _, err := call(ctx, c.API, "POST", "config/folders", cfg); err != nil {
		// Запись могла примениться после таймаута: отрицательное чтение не повод снимать исключения.
		rules.Commit()
		v, e2 := call(context.WithoutCancel(ctx), c.API, "GET", "config/folders", nil)
		if e2 != nil {
			return errors.New("Ответ Syncthing потерян. Исключения сохранены; проверьте регистрацию в Syncthing Tray")
		}
		applied := false
		for _, f := range arr(v) {
			applied = applied || str(mp(f), "id") == row.ID && samePath(str(mp(f), "path"), row.Path)
		}
		if !applied {
			return err
		}
	}
	rules.Commit()
	row.ServerOnly, row.Kind, row.Percent = false, KindSyncing, 0
	var rest []*FolderState
	for _, f := range snap.Folders {
		if f.ID != row.ID {
			rest = append(rest, f)
		}
	}
	c.Meta.Reconcile(c.Root, append(rest, row))
	return nil
}

// confirmForRemoval: сервер должен подтвердить свежие изменения. POST db/scan ждёт полного сканирования;
// ожидание между проверками — событием Syncthing (long-poll), а не таймером.
func (c *Commands) confirmForRemoval(ctx context.Context, row *FolderState) error {
	ctx, cancel := context.WithTimeout(ctx, c.timeout())
	defer cancel()
	fail := func(e error) error {
		if errors.Is(e, context.DeadlineExceeded) {
			return errors.New("Сервер не подтвердил свежие изменения вовремя. Папка сохранена на компьютере; дождитесь синхронизации и повторите действие")
		}
		return fmt.Errorf("Не удалось подтвердить свежие изменения на сервере. Папка сохранена на компьютере. %v", e)
	}
	peer, f := c.API.Peer(), esc(row.ID)
	if _, err := call(ctx, c.API, "POST", "db/scan?folder="+f, nil); err != nil {
		return fail(err)
	}
	since := tailEvent(ctx, c.API)
	for {
		before, err := call(ctx, c.API, "GET", "db/status?folder="+f, nil)
		if err != nil {
			return fail(err)
		}
		remote, err := call(ctx, c.API, "GET", "db/completion?folder="+f+"&device="+esc(peer), nil)
		if err != nil {
			return fail(err)
		}
		conns, err := call(ctx, c.API, "GET", "system/connections", nil)
		if err != nil {
			return fail(err)
		}
		after, err := call(ctx, c.API, "GET", "db/status?folder="+f, nil)
		if err != nil {
			return fail(err)
		}
		connected := boolv(mp(mp(mp(conns)["connections"])[peer]), "connected")
		st := status(&FolderState{ID: row.ID, Paused: row.Paused}, mp(after), mp(remote), connected, false)
		if st.Kind == KindLocalChanges {
			return errors.New(st.Tooltip())
		}
		stable := str(mp(before), "sequence") == str(mp(after), "sequence") && str(mp(before), "sequence") != ""
		if stable && st.Kind == KindSynced && str(mp(before), "state") == "idle" {
			return nil
		}
		if !stable {
			if _, err := call(ctx, c.API, "POST", "db/scan?folder="+f, nil); err != nil {
				return fail(err)
			}
		}
		since = waitEvent(ctx, c.API, since)
		if ctx.Err() != nil {
			return fail(ctx.Err())
		}
	}
}

// keep: «Оставить только на сервере». Файлы уходят в Корзину, папка становится пустой заглушкой.
// Регистрация снимается до удаления; при неудаче возвращается, пока файлы ещё на месте.
func (c *Commands) keep(ctx context.Context, row *FolderState) error {
	if !c.Meta.isDir(row.Path) {
		return errors.New("Локальная папка не найдена")
	}
	if err := c.available(row.Path, nil); err != nil {
		return err
	}
	if err := c.confirmForRemoval(ctx, row); err != nil {
		return err
	}
	detached := false
	err := func() error {
		if _, err := call(ctx, c.API, "DELETE", "config/folders/"+esc(row.ID), nil); err != nil {
			return err
		}
		v, err := call(ctx, c.API, "GET", "config/folders", nil)
		if err != nil {
			return err
		}
		for _, f := range arr(v) {
			if str(mp(f), "id") == row.ID || overlaps(row.Path, str(mp(f), "path")) {
				return errors.New("Syncthing ещё использует эту папку")
			}
		}
		detached = true
		if err := c.plainPath(row.Path); err != nil {
			return err
		}
		if err := c.Recycle(row.Path); err != nil {
			return err
		}
		if _, err := os.Stat(row.Path); err == nil {
			return errors.New("Перенос папки в Корзину не подтверждён")
		}
		return nil
	}()
	if err != nil {
		if c.Meta.isDir(row.Path) {
			if rerr := c.restore(row); rerr != nil {
				return errors.New("Локальные файлы сохранены. Не удалось подтвердить восстановление синхронизации; проверьте папку в Syncthing Tray")
			}
		}
		_ = detached
		return err
	}
	if !c.Meta.MarkPlaceholder(row.Path) {
		return errors.New("Файлы в Корзине; не удалось оформить заглушку")
	}
	return nil
}

// restore возвращает снятую регистрацию, если локальные данные остались.
func (c *Commands) restore(row *FolderState) error {
	ctx := context.Background()
	v, err := call(ctx, c.API, "GET", "config/folders", nil)
	if err != nil {
		return err
	}
	for _, f := range arr(v) {
		m := mp(f)
		if str(m, "id") == row.ID {
			if !samePath(str(m, "path"), row.Path) {
				return errors.New("Регистрация папки изменена")
			}
			return nil
		}
		if overlaps(row.Path, str(m, "path")) {
			return errors.New("Путь уже занят другой регистрацией")
		}
	}
	_, err = call(ctx, c.API, "POST", "config/folders", row.Config)
	return err
}
