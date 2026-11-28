package explorer

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

// Owner — метка наших метаданных (desktop.ini, ключи меню, файлы значков). Совпадает с Лабораторией: оформление переиспользуется.
const Owner = "RemoteAgents.Disk.v2"

// IconRevision растёт, когда меняются картинки значков: новые файлы получают новые имена (Проводник помнит значок по имени).
const IconRevision = 2

// Attrs — атрибуты файла, которые нам важны.
type Attrs struct{ ReadOnly, Hidden, System, Reparse bool }

// FS — файловый слой оформления (подменяется в тестах).
type FS interface {
	Stat(path string) (exists, isDir bool, a Attrs, err error)
	SetAttrs(path string, a Attrs) error
	Entries(path string) ([]string, error) // полные пути
	Read(path string) (string, error)
	Write(path, content string) error // desktop.ini: UTF-16 LE с BOM
	Mkdir(path string) error
	RemoveFile(path string) error
	RemoveDir(path string) error // только пустой
}

// Icons — файлы значков.
type Icons interface {
	PathFor(k Kind) (string, error)
	ApplicationPath() (string, error) // значок программы для пунктов меню
}

// Notifier сообщает Проводнику об изменении папки.
type Notifier interface{ Changed(path string) }

// Service ведёт оформление папок: desktop.ini со значком и подсказкой, заглушки «только на сервере».
// Трогает только свои пустые заглушки и свой desktop.ini; чужие метаданные не меняются.
type Service struct {
	fs    FS
	icons Icons
	note  Notifier
	log   func(string)
}

func NewService(fs FS, icons Icons, note Notifier, log func(string)) *Service {
	if log == nil {
		log = func(string) {}
	}
	return &Service{fs: fs, icons: icons, note: note, log: log}
}

func (s *Service) ApplicationIcon() (string, error) { return s.icons.ApplicationPath() }

func (s *Service) exists(p string) bool { e, _, _, _ := s.fs.Stat(p); return e }
func (s *Service) isDir(p string) bool  { e, d, _, _ := s.fs.Stat(p); return e && d }
func (s *Service) isFile(p string) bool { e, d, _, _ := s.fs.Stat(p); return e && !d }
func (s *Service) attrs(p string) Attrs { _, _, a, _ := s.fs.Stat(p); return a }

// hasReparseAncestor — путь или его родитель — ссылка (тогда ничего не трогаем).
func (s *Service) hasReparseAncestor(p string) bool {
	for cur := filepath.Clean(p); ; {
		if e, _, a, _ := s.fs.Stat(cur); e && a.Reparse {
			return true
		}
		next := filepath.Dir(cur)
		if next == cur {
			return false
		}
		cur = next
	}
}

// ClassifyLocalCopies различает пустую заглушку и локальную копию у папок, предложенных сервером.
func (s *Service) ClassifyLocalCopies(rows []*FolderState) {
	for _, r := range rows {
		if !r.ServerOnly || (r.Kind != KindServerOnly && r.Kind != KindLocalCopy) {
			continue
		}
		switch {
		case s.isDir(r.Path) && !s.hasReparseAncestor(r.Path):
			if s.IsPlaceholder(r.Path) {
				r.Kind = KindServerOnly
			} else {
				r.Kind = KindLocalCopy
			}
		case !s.isFile(r.Path) && !s.hasReparseAncestor(r.Path):
			r.Kind = KindServerOnly
		}
	}
}

// Reconcile приводит оформление корня Диска к списку папок.
func (s *Service) Reconcile(root string, rows []*FolderState) {
	s.ClassifyLocalCopies(rows)
	anyServerOnly := false
	for _, r := range rows {
		anyServerOnly = anyServerOnly || r.ServerOnly
	}
	if !s.exists(root) && !s.hasReparseAncestor(root) && anyServerOnly {
		_ = s.fs.Mkdir(root)
	}
	if !s.isDir(root) || s.hasReparseAncestor(root) {
		return
	}
	for _, r := range rows {
		if r.Kind == KindLocal {
			continue
		}
		if !isChild(r.Path, root) {
			s.cleanupFolder(r.Path, false)
			continue
		}
		if s.isFile(r.Path) || s.hasReparseAncestor(r.Path) {
			continue
		}
		created := !s.isDir(r.Path)
		if created {
			if !r.ServerOnly || r.Kind != KindServerOnly {
				continue
			}
			if err := s.fs.Mkdir(r.Path); err != nil {
				s.fail(err)
				continue
			}
		}
		meta := s.readOwned(r.Path)
		ini := filepath.Join(r.Path, "desktop.ini")
		if s.exists(ini) && meta == nil {
			continue // чужой desktop.ini
		}
		placeholder := r.ServerOnly && !s.userEntries(r.Path) && (created || flag(meta, "Placeholder"))
		if r.ServerOnly && !placeholder && r.Kind != KindLocalCopy {
			continue
		}
		if err := s.apply(r.Path, r.Kind, r.Tooltip(), meta, placeholder, created); err != nil {
			s.fail(err)
		}
	}
	wanted := map[string]bool{}
	for _, r := range rows {
		wanted[strings.ToLower(r.Path)] = true
	}
	entries, _ := s.fs.Entries(root)
	for _, p := range entries {
		if wanted[strings.ToLower(p)] {
			continue
		}
		if s.isDir(p) && !s.hasReparseAncestor(p) {
			s.cleanupFolder(p, true)
		}
	}
}

// MarkPlaceholder оформляет папку пустой заглушкой «только на сервере» (после «Оставить только на сервере»).
func (s *Service) MarkPlaceholder(path string) bool {
	if s.isFile(path) || s.hasReparseAncestor(path) {
		return false
	}
	created := !s.isDir(path)
	if created && s.fs.Mkdir(path) != nil {
		return false
	}
	meta := s.readOwned(path)
	if (s.exists(filepath.Join(path, "desktop.ini")) && meta == nil) || s.userEntries(path) {
		return false
	}
	return s.apply(path, KindServerOnly, ServerOnlyHint, meta, true, created) == nil
}

// IsPlaceholder — наша пустая заглушка.
func (s *Service) IsPlaceholder(path string) bool {
	if !s.isDir(path) || s.hasReparseAncestor(path) {
		return false
	}
	meta := s.readOwned(path)
	return flag(meta, "Placeholder") && bound(meta, path) && !s.userEntries(path)
}

// userEntries — есть ли в папке что-то кроме desktop.ini.
func (s *Service) userEntries(path string) bool {
	es, _ := s.fs.Entries(path)
	for _, p := range es {
		if !strings.EqualFold(filepath.Base(p), "desktop.ini") {
			return true
		}
	}
	return false
}

func (s *Service) readOwned(path string) map[string]string {
	ini := filepath.Join(path, "desktop.ini")
	e, d, a, _ := s.fs.Stat(ini)
	if !e || d || a.Reparse {
		return nil
	}
	text, err := s.fs.Read(ini)
	if err != nil {
		return nil
	}
	vals := map[string]string{}
	section := ""
	for _, raw := range strings.Split(strings.ReplaceAll(text, "\r", ""), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = line
			continue
		}
		if i := strings.Index(line, "="); i > 0 && strings.EqualFold(section, "[RemoteAgents]") {
			vals[strings.TrimSpace(line[:i])] = strings.TrimSpace(line[i+1:])
		}
	}
	if vals["Owner"] == Owner && (vals["OriginalReadOnly"] == "0" || vals["OriginalReadOnly"] == "1") {
		return vals
	}
	return nil
}

func flag(m map[string]string, k string) bool { return m != nil && m[k] == "1" }

func bound(m map[string]string, path string) bool {
	if m == nil {
		return false
	}
	b, ok := m["BoundPath"]
	return !ok || samePath(b, path)
}

func b01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func (s *Service) apply(path string, kind Kind, tip string, meta map[string]string, placeholder, created bool) error {
	ini := filepath.Join(path, "desktop.ini")
	origRO := s.attrs(path).ReadOnly
	if meta != nil {
		origRO = flag(meta, "OriginalReadOnly")
	}
	tip = strings.NewReplacer("\r", " ", "\n", " ", "\x00", "").Replace(tip)
	icon, err := s.icons.PathFor(kind)
	if err != nil {
		return err
	}
	if strings.ContainsAny(icon, "\r\n\"") {
		return errors.New("Недопустимый путь значка")
	}
	abs, _ := filepath.Abs(path)
	content := "[.ShellClassInfo]\r\nIconResource=" + icon + ",0\r\nInfoTip=" + tip + "\r\n[RemoteAgents]\r\nOwner=" + Owner +
		"\r\nBoundPath=" + abs + "\r\nOriginalReadOnly=" + b01(origRO) + "\r\nPlaceholder=" + b01(placeholder) +
		"\r\nCreatedDirectory=" + b01(created || flag(meta, "CreatedDirectory")) + "\r\n"
	changed := true
	if s.isFile(ini) {
		if cur, err := s.fs.Read(ini); err == nil && strings.ReplaceAll(cur, "\r", "") == strings.ReplaceAll(content, "\r", "") {
			changed = false
		}
	}
	if changed {
		if s.isFile(ini) {
			_ = s.fs.SetAttrs(ini, Attrs{})
		}
		if err := s.fs.Write(ini, content); err != nil {
			return err
		}
	}
	ia := s.attrs(ini)
	ia.Hidden, ia.System = true, true
	if err := s.fs.SetAttrs(ini, ia); err != nil {
		return err
	}
	pa := s.attrs(path)
	pa.ReadOnly = true // без этого Проводник не читает desktop.ini папки
	if err := s.fs.SetAttrs(path, pa); err != nil {
		return err
	}
	if changed && s.note != nil {
		s.note.Changed(path)
	}
	return nil
}

// Cleanup снимает оформление со всех папок корня.
func (s *Service) Cleanup(root string, removeEmptyPlaceholders bool) {
	if !s.isDir(root) || s.hasReparseAncestor(root) {
		return
	}
	es, _ := s.fs.Entries(root)
	for _, p := range es {
		if s.isDir(p) && !s.hasReparseAncestor(p) {
			s.cleanupFolder(p, removeEmptyPlaceholders)
		}
	}
}

// CleanupFolder снимает оформление с одной папки; пустую созданную нами заглушку при необходимости удаляет.
func (s *Service) CleanupFolder(path string, removeEmptyPlaceholder bool) {
	s.cleanupFolder(path, removeEmptyPlaceholder)
}

func (s *Service) cleanupFolder(path string, removeEmpty bool) {
	if !s.isDir(path) || s.hasReparseAncestor(path) {
		return
	}
	meta := s.readOwned(path)
	ini := filepath.Join(path, "desktop.ini")
	if meta == nil {
		if s.exists(ini) {
			s.log("Проводник: чужой desktop.ini оставлен без изменений")
		}
		return
	}
	remove := removeEmpty && bound(meta, path) && flag(meta, "Placeholder") && flag(meta, "CreatedDirectory") && !s.userEntries(path)
	a := s.attrs(path)
	a.ReadOnly = flag(meta, "OriginalReadOnly")
	if err := s.fs.SetAttrs(path, a); err != nil {
		s.fail(err)
	}
	_ = s.fs.SetAttrs(ini, Attrs{})
	if err := s.fs.RemoveFile(ini); err != nil {
		s.fail(err)
		return
	}
	if remove {
		if err := s.fs.RemoveDir(path); err != nil {
			s.fail(err)
		}
	}
	if s.note != nil {
		s.note.Changed(path)
	}
}

func (s *Service) fail(err error) {
	s.log(fmt.Sprintf("Проводник: операция оформления не выполнена (%v)", err))
}

// encodeUTF16LE — desktop.ini пишется в UTF-16 LE с BOM.
func encodeUTF16LE(s string) []byte {
	u := utf16.Encode([]rune(s))
	b := make([]byte, 0, 2+len(u)*2)
	b = append(b, 0xFF, 0xFE)
	for _, c := range u {
		b = append(b, byte(c), byte(c>>8))
	}
	return b
}

// decodeText читает UTF-16 (по BOM) или UTF-8.
func decodeText(b []byte) string {
	if len(b) >= 2 && b[0] == 0xFF && b[1] == 0xFE {
		u := make([]uint16, 0, len(b)/2)
		for i := 2; i+1 < len(b); i += 2 {
			u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
		}
		return string(utf16.Decode(u))
	}
	return strings.TrimPrefix(string(b), "\ufeff")
}
