// Binary bundles follow v2 bins.py: runtime/bin.zip and a per-file SHA-256 manifest.
package deps

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"

	"remoteagents/internal/api"
)

type Bundle struct {
	mu       sync.RWMutex
	dir, why string
	strict   bool
	bad      map[string]string
	said     map[string]bool
	log      api.Logger
}

func (b *Bundle) Strict() bool { b.mu.RLock(); defer b.mu.RUnlock(); return b.strict }
func (b *Bundle) Why(rel string) string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if why := b.bad[rel]; why != "" {
		return why
	}
	if len(b.bad) > 0 {
		return ""
	}
	return b.why
}
func (b *Bundle) Find(rel string) string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.dir == "" || b.bad[rel] != "" {
		return ""
	}
	p := filepath.Join(b.dir, filepath.FromSlash(rel))
	if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
		return p
	}
	return ""
}
func (b *Bundle) report(key, text string) {
	if !b.said[key] {
		b.said[key] = true
		if b.log != nil {
			b.log.With("bins").Warn(key, "why", text)
		}
	}
}
func hash(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func check(folder string) (map[string]string, error) {
	data, err := os.ReadFile(filepath.Join(folder, "bin-manifest.json"))
	if err != nil {
		return nil, err
	}
	var man map[string]string
	if err := json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), &man); err != nil {
		return nil, err
	}
	if man == nil {
		return nil, errors.New("invalid manifest")
	}
	bad := map[string]string{}
	for rel, want := range man {
		got, err := hash(filepath.Join(folder, filepath.FromSlash(rel)))
		if err != nil {
			bad[rel] = "Антивирус удалил " + rel + ": файла нет"
		} else if got != want {
			bad[rel] = "Антивирус изменил " + rel + ": файл не используется"
		}
	}
	return bad, nil
}
func extract(path, dst string) error {
	z, err := zip.OpenReader(path)
	if err != nil {
		return err
	}
	defer z.Close()
	if err := os.MkdirAll(dst, 0755); err != nil {
		return err
	}
	for _, f := range z.File {
		// zipfile.extractall in Python strips absolute and parent path components.
		var parts []string
		for _, p := range strings.Split(strings.ReplaceAll(f.Name, "\\", "/"), "/") {
			if p != "" && p != "." && p != ".." {
				parts = append(parts, p)
			}
		}
		target := filepath.Join(append([]string{dst}, parts...)...)
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		src, err := f.Open()
		if err != nil {
			return err
		}
		mode := os.FileMode(0644)
		if f.Mode()&0111 != 0 {
			mode = 0755
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
		if err != nil {
			src.Close()
			return err
		}
		_, err = io.Copy(out, src)
		src.Close()
		closeErr := out.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

// Prepare does no network access and never elevates privileges.
func (b *Bundle) Prepare(home string, log api.Logger) (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.dir, b.why, b.bad, b.log = "", "", map[string]string{}, log
	if b.said == nil {
		b.said = map[string]bool{}
	}
	rt := filepath.Join(home, "runtime")
	zp := filepath.Join(rt, "bin.zip")
	fail := func(message string) (string, error) {
		b.why = message
		b.report("why:"+message, message)
		return "", errors.New(message)
	}
	b.strict = len(embeddedBundle) > 0
	if err := installBundle(zp); err != nil {
		return fail("Не удалось сохранить вшитые программы")
	}
	st, err := os.Stat(zp)
	b.strict = b.strict || (err == nil && st.Mode().IsRegular())
	if !b.strict {
		b.why = "bin.zip не найден (EXE без вшитых программ)"
		b.report("old-mode", "EXE без вшитых программ: ищу чужие, старый режим")
		return "", nil
	}
	sum, err := hash(zp)
	if err != nil {
		return fail("Не удалось прочитать bin.zip")
	}
	folder := filepath.Join(rt, "bin-"+sum[:12])
	bad, checkErr := check(folder)
	if checkErr != nil || len(bad) > 0 {
		tmp := folder + ".tmp"
		_ = os.RemoveAll(tmp)
		if err := extract(zp, tmp); err != nil {
			_ = os.RemoveAll(tmp)
			if _, err := check(folder); err != nil {
				return fail("Не удалось распаковать вшитые программы")
			}
			b.report("extract", "Не удалось заново распаковать вшитые программы: остаётся прежняя папка")
		} else {
			if _, err := check(tmp); err != nil {
				_ = os.RemoveAll(tmp)
				return fail("Антивирус удалил или изменил bin-manifest.json: вшитые программы не используются")
			}
			old := folder + ".old"
			_ = os.RemoveAll(old)
			_, statErr := os.Stat(folder)
			var moveErr error
			if statErr == nil {
				moveErr = os.Rename(folder, old)
			}
			if moveErr == nil {
				moveErr = os.Rename(tmp, folder)
				if moveErr != nil && statErr == nil {
					_ = os.Rename(old, folder)
				}
			}
			if moveErr != nil {
				_ = os.RemoveAll(tmp)
				if _, err := os.Stat(folder); err != nil {
					return fail("Не удалось обновить вшитые программы (файл занят)")
				}
				b.report("replace", "Не удалось обновить вшитые программы: остаётся прежняя папка")
			} else {
				_ = os.RemoveAll(old)
			}
		}
	}
	b.bad, err = check(folder)
	if err != nil {
		b.bad = map[string]string{}
		return fail("Антивирус удалил или изменил bin-manifest.json: вшитые программы не используются")
	}
	var reasons []string
	for rel, why := range b.bad {
		b.report("bad:"+rel, why)
		reasons = append(reasons, why)
	}
	sort.Strings(reasons)
	b.why = strings.Join(reasons, "; ")
	b.dir = folder
	src, dst := filepath.Join(folder, "rules", "geoip-ru.srs"), filepath.Join(home, "state", "vpn-geoip-ru.srs")
	if b.bad["rules/geoip-ru.srs"] == "" {
		if _, err := os.Stat(dst); errors.Is(err, os.ErrNotExist) {
			if data, err := os.ReadFile(src); err == nil {
				err = os.MkdirAll(filepath.Dir(dst), 0755)
				if err == nil {
					err = os.WriteFile(dst+".tmp", data, 0644)
				}
				if err == nil {
					err = os.Rename(dst+".tmp", dst)
				}
				if err != nil {
					_ = os.Remove(dst + ".tmp")
					b.report("geoip", "Не удалось положить список сетей")
				}
			}
		}
	}
	entries, _ := os.ReadDir(rt)
	var oldDirs []os.FileInfo
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), "bin-") && !strings.HasSuffix(e.Name(), ".tmp") && !strings.HasSuffix(e.Name(), ".old") && filepath.Join(rt, e.Name()) != folder {
			if info, err := e.Info(); err == nil {
				oldDirs = append(oldDirs, info)
			}
		}
	}
	sort.Slice(oldDirs, func(i, j int) bool { return oldDirs[i].ModTime().After(oldDirs[j].ModTime()) })
	for i := 1; i < len(oldDirs); i++ {
		if err := os.RemoveAll(filepath.Join(rt, oldDirs[i].Name())); err != nil {
			b.report("cleanup", "Не удалось убрать старые папки вшитых программ")
		}
	}
	return folder, nil
}

// VPNNeedsSetcap tells the VPN owner to restore Linux capabilities after replacing sing-box.
// The config/bins packages never run sudo or setcap.
func VPNNeedsSetcap() bool { return runtime.GOOS == "linux" }
