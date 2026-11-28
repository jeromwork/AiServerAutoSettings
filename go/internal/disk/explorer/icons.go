package explorer

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

//go:embed icons/*.ico
var iconFS embed.FS

// ApplicationIconFile — значок программы для пунктов меню.
const ApplicationIconFile = Owner + ".App.ico"

// StateIconFile — имя файла значка состояния. Проводник помнит значок по имени файла: новая картинка = новая ревизия.
func StateIconFile(k Kind) string { return fmt.Sprintf("%s.r%d.%s.ico", Owner, IconRevision, k) }

// IconDir — каталог значков под папкой Диска пользователя.
type IconDir struct{ Dir string }

func (d IconDir) PathFor(k Kind) (string, error) {
	return d.export("icons/"+string(k)+".ico", StateIconFile(k))
}

func (d IconDir) ApplicationPath() (string, error) {
	return d.export("icons/App.ico", ApplicationIconFile)
}

// export кладёт встроенный файл как есть; существующий не трогаем (Проводник мог его открыть).
func (d IconDir) export(res, name string) (string, error) {
	if err := os.MkdirAll(d.Dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(d.Dir, name)
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	b, err := iconFS.ReadFile(res)
	if err != nil {
		return "", fmt.Errorf("В программе нет файла значка %s", res)
	}
	return path, writeFileAtomic(path, b)
}

var ourIcon = regexp.MustCompile(`^` + regexp.QuoteMeta(Owner) + `\.((r\d+\.)?[A-Za-z]+|App)\.ico$`)

// CleanupIcons удаляет наши файлы значков всех ревизий (удаление программы); чужое остаётся.
func CleanupIcons(dir string) {
	es, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range es {
		if ourIcon.MatchString(e.Name()) && e.Type().IsRegular() {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}
