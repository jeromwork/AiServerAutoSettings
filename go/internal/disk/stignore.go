package disk

import (
	_ "embed"
	"os"
	"path/filepath"
)

//go:embed stignore.txt
var ignoreRules string

// IgnoreRules — обязательные исключения (секреты, генерируемое).
func IgnoreRules() string { return ignoreRules }

// WriteIgnore кладёт в папку .stignore-remoteagents и .stignore с #include.
func WriteIgnore(dir string) error {
	if err := writeAtomic(filepath.Join(dir, ".stignore-remoteagents"), []byte(ignoreRules)); err != nil {
		return err
	}
	return writeAtomic(filepath.Join(dir, ".stignore"), []byte("#include .stignore-remoteagents\n"))
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}
