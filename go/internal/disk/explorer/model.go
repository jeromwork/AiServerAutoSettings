// Package explorer — Проводник для Диска: значки состояний папок (desktop.ini), меню правой кнопки (HKCU),
// корзина и обработка команд меню. Всё платформенное (реестр, SHChangeNotify, корзина) — за интерфейсами;
// на не-Windows системах реальные реализации — no-op.
package explorer

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
)

// Названия пунктов меню. Подсказки на заглушках ссылаются на них по имени.
const (
	MenuDownload   = "Скачать на компьютер"
	MenuKeepServer = "Оставить только на сервере"
	MenuUpload     = "Загрузить на сервер"
	MenuSync       = "Объединить с сервером"

	LocalCopyHint  = "Локальная копия, не синхронизируется. Правый клик → " + MenuSync
	ServerOnlyHint = "Только на сервере. Правый клик → " + MenuDownload
)

// Команды меню (аргумент `remoteagents disk-shell <cmd> <path>`).
const (
	CmdDownload   = "download"
	CmdSync       = "sync"
	CmdKeepServer = "keep-server"
	CmdAdd        = "add"
)

// MenuCommands — допустимые команды меню.
var MenuCommands = []string{CmdDownload, CmdSync, CmdKeepServer, CmdAdd}

// ValidCommand — известна ли команда.
func ValidCommand(c string) bool {
	for _, x := range MenuCommands {
		if x == c {
			return true
		}
	}
	return false
}

// Kind — состояние папки; имя совпадает с именем файла значка.
type Kind string

const (
	KindLocal         Kind = "Local" // папка Syncthing, которой сервер не делится
	KindServerOnly    Kind = "ServerOnly"
	KindPending       Kind = "Pending"
	KindSyncing       Kind = "Syncing"
	KindSynced        Kind = "Synced"
	KindPaused        Kind = "Paused"
	KindError         Kind = "Error"
	KindOffline       Kind = "Offline"
	KindUnavailable   Kind = "Unavailable"
	KindLocalChanges  Kind = "LocalChanges"
	KindServerRemoved Kind = "ServerRemoved"
	KindLocalCopy     Kind = "LocalCopy"
)

// AllKinds — все состояния (для значков).
var AllKinds = []Kind{KindLocal, KindServerOnly, KindPending, KindSyncing, KindSynced, KindPaused, KindError,
	KindOffline, KindUnavailable, KindLocalChanges, KindServerRemoved, KindLocalCopy}

// FolderState — папка Диска для Проводника.
type FolderState struct {
	ID, Name, Path, Detail string
	ServerOnly, Paused     bool
	Kind                   Kind
	Percent                int
	Config                 map[string]any // конфиг папки в Syncthing; nil — неизвестен
}

// Uploads — папка отдаётся на сервер (send+receive): пункт «Загрузить» ей не нужен. Без конфига считаем, что отдаётся.
func (f FolderState) Uploads() bool {
	return !f.ServerOnly && f.Kind != KindLocal && (f.Config == nil || str(f.Config, "type") == "sendreceive")
}

// Tooltip — подсказка папки.
func (f FolderState) Tooltip() string {
	switch f.Kind {
	case KindLocalCopy:
		return LocalCopyHint
	case KindServerOnly:
		return ServerOnlyHint
	case KindSynced:
		return "Синхронизировано с сервером"
	case KindSyncing:
		return fmt.Sprintf("Синхронизируется: %d%%", f.Percent)
	case KindPaused:
		return "Синхронизация приостановлена"
	case KindOffline:
		return "Нет соединения с сервером"
	case KindError:
		if f.Detail != "" {
			return "Ошибка синхронизации: " + f.Detail
		}
		return "Ошибка синхронизации"
	case KindLocalChanges:
		return "Есть локальные изменения. Загрузите их на сервер перед освобождением места"
	case KindUnavailable:
		return "Локальный Syncthing недоступен"
	case KindServerRemoved:
		return "Удалена на сервере, локальная копия сохранена"
	}
	return "Ожидается подтверждение Syncthing"
}

// Snapshot — все папки Диска.
type Snapshot struct {
	Folders   []*FolderState
	Connected bool
}

// ---------------------------------------------------------------- JSON-помощники

func str(m map[string]any, k string) string {
	switch v := m[k].(type) {
	case string:
		return v
	case float64:
		return fmt.Sprint(v)
	case bool:
		return fmt.Sprint(v)
	}
	return ""
}

func num(m map[string]any, k string) float64 {
	switch v := m[k].(type) {
	case float64:
		return v
	case string:
		var f float64
		if _, err := fmt.Sscan(v, &f); err == nil {
			return f
		}
	}
	return 0
}

func boolv(m map[string]any, k string) bool { b, _ := m[k].(bool); return b }

func mp(v any) map[string]any {
	m, _ := v.(map[string]any)
	if m == nil {
		return map[string]any{}
	}
	return m
}

func arr(v any) []any { a, _ := v.([]any); return a }

// ---------------------------------------------------------------- статус папки

// removedByServer — сервер снял папку: он на связи, раньше ею делился, теперь remoteState=notSharing.
func removedByServer(remote map[string]any, connected, confirmedBefore bool) bool {
	return connected && confirmedBefore && str(remote, "remoteState") == "notSharing"
}

// confirmedByServer — сервер делится папкой (valid) или держит её на паузе.
func confirmedByServer(remote map[string]any) bool {
	s := str(remote, "remoteState")
	return s == "valid" || s == "paused"
}

func has(m map[string]any, keys ...string) bool {
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}

// status вычисляет Kind/Percent/Detail по db/status и db/completion (логика Лаборатории DiskSnapshot.Status).
func status(row *FolderState, local, remote map[string]any, connected, confirmedBefore bool) *FolderState {
	row.Detail = str(local, "error")
	state := str(local, "state")
	total, need := num(local, "globalBytes"), num(local, "needBytes")
	var localPct float64
	switch {
	case total > 0:
		localPct = 100 * maxf(0, total-need) / total
	case num(local, "needTotalItems") > 0:
		localPct = 0
	default:
		localPct = 100
	}
	var remotePct float64
	if _, ok := remote["completion"]; ok {
		remotePct = num(remote, "completion")
	}
	row.Percent = int(maxf(0, minf(100, floorf(minf(localPct, remotePct)))))
	rs := str(remote, "remoteState")
	switch {
	case removedByServer(remote, connected, confirmedBefore):
		row.Kind, row.Detail = KindServerRemoved, ""
	case row.Paused || state == "paused" || rs == "paused":
		row.Kind = KindPaused
	case state == "error" || row.Detail != "" || num(local, "pullErrors") > 0:
		row.Kind = KindError
	case num(local, "receiveOnlyTotalItems") > 0 || num(local, "receiveOnlyChangedBytes") > 0:
		row.Kind, row.Detail = KindLocalChanges, "Есть локальные изменения"
	case !connected:
		row.Kind = KindOffline
	case state == "" || !has(local, "needBytes", "needTotalItems", "globalBytes") ||
		!has(remote, "completion", "needItems", "needBytes", "needDeletes", "remoteState"):
		row.Kind = KindPending
	case rs != "valid" || !activeState[state]:
		row.Kind = KindPending
	case state == "idle" && row.Percent == 100 && num(local, "needTotalItems") == 0 && num(local, "needBytes") == 0 &&
		num(remote, "needItems") == 0 && num(remote, "needBytes") == 0 && num(remote, "needDeletes") == 0:
		row.Kind = KindSynced
	default:
		row.Kind = KindSyncing
		if row.Percent > 99 {
			row.Percent = 99
		}
	}
	return row
}

var activeState = map[string]bool{"idle": true, "syncing": true, "sync-preparing": true, "sync-waiting": true,
	"scanning": true, "scan-waiting": true, "cleaning": true, "clean-waiting": true}

func maxf(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
func minf(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
func floorf(a float64) float64 { return float64(int(a)) }

// ---------------------------------------------------------------- пути

var reservedName = regexp.MustCompile(`(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)`)

// ValidName — имя папки допустимо в Windows и на сервере.
func ValidName(name string) bool {
	if strings.TrimSpace(name) == "" || name == "." || name == ".." || strings.TrimRight(name, " .") != name {
		return false
	}
	for _, c := range name {
		if c < 32 || strings.ContainsRune(`<>:"/\|?*`, c) {
			return false
		}
	}
	return !reservedName.MatchString(name)
}

// cleanPath — абсолютный путь без хвостового разделителя (корень диска сохраняется).
func cleanPath(p string) (string, error) {
	if strings.TrimSpace(p) == "" || strings.ContainsAny(p, "\"\r\n\x00") {
		return "", fmt.Errorf("Нужен обычный абсолютный путь к папке")
	}
	if strings.HasPrefix(p, `\\?\`) || strings.HasPrefix(p, `\\.\`) {
		return "", fmt.Errorf("Нужен обычный абсолютный путь к папке")
	}
	if !filepath.IsAbs(p) {
		return "", fmt.Errorf("Нужен обычный абсолютный путь к папке")
	}
	return filepath.Clean(p), nil
}

func samePath(a, b string) bool {
	ca, e1 := cleanPath(a)
	cb, e2 := cleanPath(b)
	return e1 == nil && e2 == nil && strings.EqualFold(ca, cb)
}

func within(p, parent string) bool {
	if samePath(p, parent) {
		return true
	}
	cp, e1 := cleanPath(p)
	cq, e2 := cleanPath(parent)
	if e1 != nil || e2 != nil {
		return false
	}
	sep := string(filepath.Separator)
	return len(cp) > len(cq) && strings.EqualFold(cp[:len(cq)], cq) && strings.HasPrefix(cp[len(cq):], sep) ||
		strings.HasSuffix(cq, sep) && strings.EqualFold(cp[:min(len(cp), len(cq))], cq)
}

func overlaps(a, b string) bool { return within(a, b) || within(b, a) }

// isChild — path лежит непосредственно в root.
func isChild(path, root string) bool {
	cp, err := cleanPath(path)
	return err == nil && samePath(filepath.Dir(cp), root)
}
