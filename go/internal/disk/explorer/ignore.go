package explorer

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

const (
	ignoreInclude = "#include .stignore-remoteagents"
	stignoreName  = ".stignore"
	stmanagedName = ".stignore-remoteagents"
)

// IgnoreChange кладёт в папку обязательные исключения (.stignore-remoteagents + #include в .stignore),
// пользовательские правила сохраняются как есть. Без Commit изменения откатываются — только наши, нетронутые.
type IgnoreChange struct {
	include, managed       string
	oldInclude, oldManaged []byte // nil — файла не было
	newInclude, newManaged []byte
	committed              bool
}

// NewIgnoreChange записывает правила; ошибка — всё откатано.
func NewIgnoreChange(dir, rules string) (*IgnoreChange, error) {
	if strings.TrimSpace(rules) == "" {
		return nil, errors.New("Шаблон исключений Диска не найден")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	c := &IgnoreChange{include: filepath.Join(dir, stignoreName), managed: filepath.Join(dir, stmanagedName)}
	for _, p := range []string{c.include, c.managed} {
		if st, err := os.Lstat(p); err == nil && (st.IsDir() || st.Mode()&os.ModeSymlink != 0) {
			return nil, errors.New("Путь правил занят каталогом или ссылкой")
		}
	}
	c.oldInclude, _ = os.ReadFile(c.include)
	c.oldManaged, _ = os.ReadFile(c.managed)
	c.newManaged = []byte(strings.ReplaceAll(rules, "\r", ""))
	c.newInclude = includeContent(c.oldInclude)
	if err := os.WriteFile(c.managed, c.newManaged, 0o644); err != nil {
		c.Close()
		return nil, err
	}
	if err := os.WriteFile(c.include, c.newInclude, 0o644); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

// includeContent — .stignore с нашей строкой #include первой; остальное не меняется.
func includeContent(old []byte) []byte {
	cur := string(old)
	bom := strings.HasPrefix(cur, "\ufeff")
	cur = strings.TrimPrefix(cur, "\ufeff")
	nl := "\n"
	if strings.Contains(cur, "\r\n") {
		nl = "\r\n"
	}
	var user strings.Builder
	for _, l := range strings.SplitAfter(cur, "\n") {
		if strings.TrimSpace(l) != ignoreInclude {
			user.WriteString(l)
		}
	}
	out := ignoreInclude + nl + user.String()
	if bom {
		out = "\ufeff" + out
	}
	return []byte(out)
}

// IgnoreNeedsChange — нужно ли обновить правила в папке.
func IgnoreNeedsChange(dir, rules string) bool {
	old, err := os.ReadFile(filepath.Join(dir, stignoreName))
	if err != nil || !bytes.Equal(old, includeContent(old)) {
		return true
	}
	m, err := os.ReadFile(filepath.Join(dir, stmanagedName))
	return err != nil || string(m) != strings.ReplaceAll(rules, "\r", "")
}

// Commit оставляет правила.
func (c *IgnoreChange) Commit() { c.committed = true }

// Close откатывает неподтверждённое изменение.
func (c *IgnoreChange) Close() {
	if c == nil || c.committed {
		return
	}
	restore(c.include, c.oldInclude, c.newInclude)
	restore(c.managed, c.oldManaged, c.newManaged)
}

func restore(path string, old, written []byte) {
	cur, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(cur, written) {
		return
	}
	if old == nil {
		_ = os.Remove(path)
	} else {
		_ = os.WriteFile(path, old, 0o644)
	}
}
