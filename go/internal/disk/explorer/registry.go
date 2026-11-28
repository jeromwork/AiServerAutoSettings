package explorer

import (
	"errors"
	"sort"
	"strings"
)

// RegStore — HKCU (подменяется в тестах). Ключи — пути под HKCU.
type RegStore interface {
	Exists(key string) bool
	Read(key, name string) string
	Write(key, name, value string) error
	DeleteTree(key string) error
}

// MenuPrefix — ключи пунктов меню папки.
const MenuPrefix = `Software\Classes\Directory\shell\RemoteAgents.Disk.`

// maxAppliesTo — предел условия AppliesTo (Windows не публикует предел; значения реестра держат ≤2048 байт).
const maxAppliesTo = 1024

// Registry — статические пункты меню Проводника. Не требует COM, прав администратора и DLL.
// Что предлагается, зависит от самой папки:
//
//	пустая заглушка (только на сервере)  → «Скачать на компьютер»
//	локальная копия предложенной папки    → «Объединить с сервером»
//	папка, что синхронизируется           → «Оставить только на сервере»
//	любая другая папка в корне Диска      → «Загрузить на сервер»
type Registry struct {
	store   RegStore
	log     func(string)
	changed func() // SHChangeNotify(SHCNE_ASSOCCHANGED)
	dirty   bool
}

func NewRegistry(store RegStore, log func(string), changed func()) *Registry {
	if log == nil {
		log = func(string) {}
	}
	if changed == nil {
		changed = func() {}
	}
	return &Registry{store: store, log: log, changed: changed}
}

func safe(p string) bool { return strings.TrimSpace(p) != "" && !strings.ContainsAny(p, "\"\r\n\x00") }

func keyOf(action string) string { return MenuPrefix + action }

// Register ставит пункты меню. exe — путь программы, root — база Диска, home — аргумент --home (может быть пуст),
// icon — .ico для пунктов (пусто — значок самого exe).
func (r *Registry) Register(exe, root string, rows []*FolderState, home, icon string) error {
	r.dirty = false
	if !safe(exe) || !safe(root) || (home != "" && !safe(home)) || (icon != "" && !safe(icon)) {
		return errors.New("Недопустимый путь оформления Проводника")
	}
	var placeholders, copies, syncing, uploading []string
	for _, f := range rows {
		if !safe(f.Path) || !isChild(f.Path, root) {
			continue
		}
		switch {
		case f.ServerOnly && f.Kind == KindServerOnly:
			placeholders = append(placeholders, f.Path)
		case f.ServerOnly && f.Kind == KindLocalCopy:
			copies = append(copies, f.Path)
		case !f.ServerOnly && f.Kind != KindLocal && f.Kind != KindServerRemoved:
			syncing = append(syncing, f.Path)
		}
		if f.Uploads() {
			uploading = append(uploading, f.Path)
		}
	}
	iconVal := "\"" + firstNonEmpty(icon, exe) + "\",0"
	for _, action := range MenuCommands {
		key := keyOf(action)
		if r.store.Exists(key) && r.store.Read(key, "RemoteAgentsOwner") != Owner {
			r.log("Проводник: чужой пункт меню пропущен")
			continue
		}
		var matches []string
		switch action {
		case CmdDownload:
			matches = placeholders
		case CmdSync:
			matches = copies
		case CmdKeepServer:
			matches = syncing
		}
		isList := action != CmdAdd
		if isList && len(matches) == 0 {
			r.remove(key)
			continue
		}
		var applies string
		if isList {
			terms := make([]string, len(matches))
			for i, m := range matches {
				terms[i] = term(m)
			}
			applies = "(" + strings.Join(terms, " OR ") + ")"
		} else {
			hidden := append(append(append([]string{}, placeholders...), copies...), uploading...)
			applies = UploadScope(root, hidden)
			if !strings.Contains(applies, "ItemFolderPathDisplay") && r.store.Read(key, "AppliesTo") != applies {
				r.log("Проводник: папок слишком много для условия меню; «Загрузить на сервер» скрыт на всех папках верхнего уровня Диска")
			}
		}
		label := map[string]string{CmdDownload: MenuDownload, CmdSync: MenuSync, CmdKeepServer: MenuKeepServer, CmdAdd: MenuUpload}[action]
		cmd := "\"" + exe + "\" disk-shell"
		if home != "" {
			cmd += " --home \"" + home + "\""
		}
		cmd += " " + action + " \"%1\""
		for _, kv := range [][3]string{
			{key, "RemoteAgentsOwner", Owner}, {key, "MUIVerb", label}, {key, "Icon", iconVal},
			{key, "MultiSelectModel", "Single"}, {key, "AppliesTo", applies}, {key + `\command`, "", cmd},
		} {
			if err := r.set(kv[0], kv[1], kv[2]); err != nil {
				return err
			}
		}
	}
	if r.dirty {
		r.changed()
	}
	return nil
}

// UploadScope — условие для «Загрузить на сервер»: прямые дети корня, кроме скрытых. Если условие длиннее
// предела, пункт прячется на всех папках (команда всё равно проверяет путь).
func UploadScope(root string, hidden []string) string {
	root = plain(root)
	scope := `System.ItemFolderPathDisplay:="` + root + `"`
	seen := map[string]bool{}
	var paths []string
	for _, h := range hidden {
		p := plain(h)
		if isChild(p, root) && !seen[strings.ToLower(p)] {
			seen[strings.ToLower(p)] = true
			paths = append(paths, p)
		}
	}
	sort.Slice(paths, func(i, j int) bool { return strings.ToLower(paths[i]) < strings.ToLower(paths[j]) })
	exact := scope
	for _, p := range paths {
		exact += " AND NOT " + term(p)
	}
	if len(exact) <= maxAppliesTo {
		return exact
	}
	return term(root) + " AND NOT " + term(root)
}

func term(p string) string { return `System.ItemPathDisplay:="` + p + `"` }

// plain — путь как показывает Проводник: без хвостового разделителя, кроме корня диска.
func plain(p string) string {
	t := strings.TrimRight(p, `\/`)
	switch {
	case t == "":
		return p
	case len(t) == 2 && t[1] == ':':
		return t + `\`
	}
	return t
}

// Cleanup снимает наши пункты меню.
func (r *Registry) Cleanup() {
	r.dirty = false
	for _, a := range MenuCommands {
		r.remove(keyOf(a))
	}
	if r.dirty {
		r.changed()
	}
}

func (r *Registry) set(key, name, value string) error {
	if r.store.Read(key, name) == value && r.store.Exists(key) {
		return nil
	}
	if err := r.store.Write(key, name, value); err != nil {
		return err
	}
	r.dirty = true
	return nil
}

func (r *Registry) remove(key string) {
	if r.store.Exists(key) && r.store.Read(key, "RemoteAgentsOwner") == Owner {
		if r.store.DeleteTree(key) == nil {
			r.dirty = true
		}
	}
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
