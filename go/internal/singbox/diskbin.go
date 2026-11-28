package singbox

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"

	"remoteagents/internal/api"
	thirdparty "remoteagents/third_party"
)

// InstallSyncthing кладёт syncthingtray (закреплён в disk.lock.json) в p.Bin и возвращает путь.
// Порядок как у sing-box: файл уже в bin с binSha256, локальная копия Лаборатории, загрузка по url, зеркало релиза.
func InstallSyncthing(ctx context.Context, p api.Paths, log api.Logger, tr api.Traces) (string, error) {
	var lock struct {
		Assets []struct {
			asset
			Target string `json:"target"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(thirdparty.DiskLock, &lock); err != nil {
		return "", fmt.Errorf("Диск: встроенный список версий повреждён")
	}
	var sel asset
	for _, a := range lock.Assets {
		if a.OS == runtime.GOOS && a.Arch == runtime.GOARCH {
			sel = a.asset
			break
		}
	}
	if sel.SHA256 == "" || sel.BinPath == "" || len(sel.BinSHA256) != 64 {
		return "", fmt.Errorf("Диск есть только для Windows (для %s/%s нет сборки)", runtime.GOOS, runtime.GOARCH)
	}
	if err := os.MkdirAll(p.Bin, 0700); err != nil {
		return "", fmt.Errorf("Диск: не создать папку %s: %v", p.Bin, err)
	}
	dst := filepath.Join(p.Bin, filepath.Base(sel.BinPath))
	if fileSHA(dst) == sel.BinSHA256 {
		return dst, nil
	}
	if base := os.Getenv("LOCALAPPDATA"); base != "" {
		name := filepath.Base(sel.BinPath)
		for _, pat := range []string{
			filepath.Join(base, "RemoteAgents-lab", "runtime", "bin-*", name),
			filepath.Join(base, "RemoteAgents*", "bin", name),
		} {
			m, _ := filepath.Glob(pat)
			for _, c := range m {
				if c == dst || fileSHA(c) != sel.BinSHA256 {
					continue
				}
				if err := copyVerified(p, tr, c, dst, sel.BinSHA256); err != nil {
					log.Warn("disk.binary.local-failed", "path", c, "err", err.Error())
					continue
				}
				log.Info("disk.binary.local", "from", c)
				return dst, nil
			}
		}
	}
	urls := []string{sel.URL}
	var sl struct {
		MirrorBase string `json:"mirrorBase"`
	}
	if json.Unmarshal(thirdparty.SingboxLock, &sl) == nil && sl.MirrorBase != "" {
		urls = append(urls, strings.TrimRight(sl.MirrorBase, "/")+"/"+path.Base(sel.URL))
	}
	var last error
	for _, u := range urls {
		err := downloadFrom(ctx, p, tr, sel, u, dst)
		if err == nil {
			log.Info("disk.binary.download", "url", u)
			return dst, nil
		}
		log.Warn("disk.binary.download-failed", "url", u, "err", err.Error())
		last = err
	}
	return "", fmt.Errorf("Диск: syncthing не получен, загрузка не удалась (%v)", last)
}
