package explorer

import (
	"os"
	"path/filepath"
)

// OSFS — настоящая файловая система. Атрибуты — в attrs_*.go.
type OSFS struct{}

func (OSFS) Stat(path string) (bool, bool, Attrs, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return false, false, Attrs{}, nil
	}
	a := getAttrs(path, st)
	if st.Mode()&os.ModeSymlink != 0 {
		a.Reparse = true
		if t, err := os.Stat(path); err == nil {
			return true, t.IsDir(), a, nil
		}
		return true, false, a, nil
	}
	return true, st.IsDir(), a, nil
}

func (OSFS) SetAttrs(path string, a Attrs) error { return setAttrs(path, a) }

func (OSFS) Entries(path string) ([]string, error) {
	es, err := os.ReadDir(path)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(es))
	for _, e := range es {
		out = append(out, filepath.Join(path, e.Name()))
	}
	return out, nil
}

func (OSFS) Read(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return decodeText(b), nil
}

func (OSFS) Write(path, content string) error {
	return os.WriteFile(path, encodeUTF16LE(content), 0o644)
}
func (OSFS) Mkdir(path string) error      { return os.MkdirAll(path, 0o755) }
func (OSFS) RemoveFile(path string) error { return os.Remove(path) }
func (OSFS) RemoveDir(path string) error  { return os.Remove(path) }
