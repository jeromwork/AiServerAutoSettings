package singbox

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"errors"
	"net/http"
	"os/exec"
	"path"
	"os"
	"path/filepath"
	"remoteagents/internal/api"
	thirdparty "remoteagents/third_party"
	"runtime"
	"strings"
	"time"
)

const assetLimit = 128 << 20

type asset struct{ OS, Arch, URL, SHA256, BinPath, BinSHA256 string }

func binaryName() string {
	if runtime.GOOS == "windows" {
		return "ra-core.exe"
	}
	return "ra-core"
}

// installBinary returns the path of sing-box in the home bin directory and the
// source it came from. Order: embedded (build.sh --embed-singbox), a file already
// in home\bin with the pinned binSha256, a local copy with the same sha256
// (Laboratory v2), download from the pinned URL (GitHub SagerNet), then the mirror
// attached to our release. Every failure is logged; the final error is one
// human-readable line for the status page.
func installBinary(ctx context.Context, p api.Paths, log api.Logger, tr api.Traces) (string, string, error) {
	if len(embeddedBin) > 0 {
		path, err := installEmbedded(p, tr, embeddedBin)
		return path, "embedded", err
	}
	var lock struct {
		Version    string
		MirrorBase string `json:"mirrorBase"`
		Assets     []asset
	}
	if err := json.Unmarshal(thirdparty.SingboxLock, &lock); err != nil {
		return "", "", fmt.Errorf("sing-box: встроенный список версий повреждён")
	}
	var sel asset
	for _, a := range lock.Assets {
		if a.OS == runtime.GOOS && a.Arch == runtime.GOARCH {
			sel = a
			break
		}
	}
	if sel.SHA256 == "" || sel.BinPath == "" || len(sel.BinSHA256) != 64 {
		return "", "", fmt.Errorf("sing-box: для %s/%s нет сборки в списке версий", runtime.GOOS, runtime.GOARCH)
	}
	if err := os.MkdirAll(p.Bin, 0700); err != nil {
		return "", "", fmt.Errorf("sing-box: не создать папку %s: %v", p.Bin, err)
	}
	dst := filepath.Join(p.Bin, binaryName())
	if fileSHA(dst) == sel.BinSHA256 {
		_ = os.Chmod(dst, 0700)
		return dst, "home", nil
	}
	for _, c := range localCandidates() {
		if fileSHA(c) != sel.BinSHA256 {
			continue
		}
		if err := copyVerified(p, tr, c, dst, sel.BinSHA256); err != nil {
			log.Warn("singbox.binary.local-failed", "path", c, "err", err.Error())
			continue
		}
		log.Info("singbox.binary.local", "from", c)
		return dst, "local", nil
	}
	urls := []string{sel.URL}
	if lock.MirrorBase != "" {
		urls = append(urls, strings.TrimRight(lock.MirrorBase, "/")+"/"+path.Base(sel.URL))
	}
	var last error
	for i, u := range urls {
		err := downloadFrom(ctx, p, tr, sel, u, dst)
		if err == nil {
			src := "download"
			if i > 0 {
				src = "mirror"
			}
			log.Info("singbox.binary."+src, "url", u)
			return dst, src, nil
		}
		log.Warn("singbox.binary.download-failed", "url", u, "err", err.Error())
		last = err
	}
	return "", "", fmt.Errorf("sing-box не получен: нет копии на этом ПК, загрузка не удалась (%v)", last)
}

// fileSHA is the lower-case sha256 of a file, or "" if it cannot be read.
func fileSHA(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

// localCandidates lists places where another RemoteAgents copy keeps the same
// sing-box (Laboratory v2 unpacks it to %LOCALAPPDATA%\RemoteAgents-lab\runtime\bin-*).
func localCandidates() []string {
	var out []string
	if runtime.GOOS == "windows" {
		if base := os.Getenv("LOCALAPPDATA"); base != "" {
			for _, pat := range []string{
				filepath.Join(base, "RemoteAgents-lab", "runtime", "bin-*", "sing-box.exe"),
				filepath.Join(base, "RemoteAgents*", "bin", "ra-core.exe"),
				filepath.Join(base, "RemoteAgents*", "transport-bin", "sing-box.exe"),
			} {
				m, _ := filepath.Glob(pat)
				out = append(out, m...)
			}
		}
	}
	if lp, err := exec.LookPath("sing-box"); err == nil {
		out = append(out, lp)
	}
	return out
}

// copyVerified copies src to dst through a recorded temp file and re-checks the hash.
func copyVerified(p api.Paths, tr api.Traces, src, dst, want string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != want {
		return fmt.Errorf("sha256 changed while copying")
	}
	tmpPath, release, err := tempFile(p, tr, "binary-*")
	if err != nil {
		return err
	}
	defer release()
	if err = os.WriteFile(tmpPath, data, 0700); err != nil {
		return err
	}
	if err = os.Chmod(tmpPath, 0700); err != nil {
		return err
	}
	return os.Rename(tmpPath, dst)
}

// installEmbedded unpacks data to p.Bin/ra-core; an identical file is left alone.
func installEmbedded(p api.Paths, tr api.Traces, data []byte) (string, error) {
	if err := os.MkdirAll(p.Bin, 0700); err != nil {
		return "", fmt.Errorf("singbox: binary: create directory: %w", err)
	}
	dst := filepath.Join(p.Bin, binaryName())
	want := sha256.Sum256(data)
	if cur, err := os.Open(dst); err == nil {
		h := sha256.New()
		_, cerr := io.Copy(h, cur)
		_ = cur.Close()
		if cerr == nil && hex.EncodeToString(h.Sum(nil)) == hex.EncodeToString(want[:]) {
			_ = os.Chmod(dst, 0700)
			return dst, nil
		}
	}
	tmpPath, release, err := tempFile(p, tr, "binary-*")
	if err != nil {
		return "", err
	}
	defer release()
	if err = os.WriteFile(tmpPath, data, 0700); err != nil {
		return "", fmt.Errorf("singbox: binary: write: %w", err)
	}
	if err = os.Chmod(tmpPath, 0700); err != nil {
		return "", fmt.Errorf("singbox: binary: write: %w", err)
	}
	if err = os.Rename(tmpPath, dst); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("singbox: binary: replace: %w", err)
	}
	return dst, nil
}

// downloadFrom fetches one archive, authenticates it by the pinned archive
// sha256, extracts the binary, checks binSha256 and renames it to dst.
func downloadFrom(ctx context.Context, p api.Paths, tr api.Traces, selected asset, url, dst string) error {
	_, err := downloadFromInner(ctx, p, tr, selected, url, dst)
	return err
}

func downloadFromInner(ctx context.Context, p api.Paths, tr api.Traces, selected asset, url, dst string) (string, error) {
	binDir := p.Bin
	if err := os.MkdirAll(binDir, 0700); err != nil {
		return "", fmt.Errorf("singbox: binary: create directory: %w", err)
	}
	archivePath, archiveRelease, err := tempFile(p, tr, "archive-*")
	if err != nil {
		return "", err
	}
	defer archiveRelease()
	archive, err := os.OpenFile(archivePath, os.O_RDWR, 0600)
	if err != nil {
		return "", fmt.Errorf("singbox: binary: temporary archive: %w", err)
	}
	defer func() { _ = archive.Close(); _ = os.Remove(archive.Name()) }()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("singbox: download: invalid URL")
	}
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("singbox: download: request failed")
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("singbox: download: HTTP %d", resp.StatusCode)
	}
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(archive, hash), io.LimitReader(resp.Body, assetLimit+1))
	if err != nil || n > assetLimit {
		return "", fmt.Errorf("singbox: download: invalid archive size or read failure")
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), selected.SHA256) {
		return "", fmt.Errorf("singbox: checksum: archive digest mismatch")
	}
	if _, err = archive.Seek(0, io.SeekStart); err != nil {
		return "", fmt.Errorf("singbox: archive: seek: %w", err)
	}
	var reader io.Reader
	var closer io.Closer
	if strings.HasSuffix(selected.BinPath, ".exe") {
		z, e := zip.NewReader(archive, n)
		if e != nil {
			return "", fmt.Errorf("singbox: archive: invalid zip")
		}
		for _, f := range z.File {
			if f.Name == selected.BinPath {
				reader, err = f.Open()
				if err != nil {
					return "", fmt.Errorf("singbox: archive: open entry")
				}
				closer = reader.(io.Closer)
				break
			}
		}
	} else {
		gz, e := gzip.NewReader(archive)
		if e != nil {
			return "", fmt.Errorf("singbox: archive: invalid gzip")
		}
		closer = gz
		tr := tar.NewReader(gz)
		for {
			h, e := tr.Next()
			if e != nil {
				break
			}
			if h.Name == selected.BinPath && h.Typeflag == tar.TypeReg {
				reader = tr
				break
			}
		}
	}
	if closer != nil {
		defer func() { _ = closer.Close() }()
	}
	if reader == nil {
		return "", fmt.Errorf("singbox: archive: binary entry missing")
	}
	tmpPath, tmpRelease, err := tempFile(p, tr, "binary-*")
	if err != nil {
		return "", err
	}
	defer tmpRelease()
	tmp, err := os.OpenFile(tmpPath, os.O_RDWR, 0600)
	if err != nil {
		return "", fmt.Errorf("singbox: binary: create file: %w", err)
	}
	defer func() { _ = tmp.Close(); _ = os.Remove(tmp.Name()) }()
	n, err = io.Copy(tmp, io.LimitReader(reader, assetLimit+1))
	if err != nil || n == 0 || n > assetLimit {
		return "", fmt.Errorf("singbox: archive: invalid binary")
	}
	if err = tmp.Chmod(0700); err == nil {
		err = tmp.Sync()
	}
	if err == nil {
		err = tmp.Close()
	}
	if err != nil {
		return "", fmt.Errorf("singbox: binary: write: %w", err)
	}
	if err = tmp.Close(); err != nil && !errors.Is(err, os.ErrClosed) {
		return "", err
	}
	if fileSHA(tmp.Name()) != selected.BinSHA256 {
		return "", fmt.Errorf("singbox: checksum: binary digest mismatch")
	}
	if err = os.Rename(tmp.Name(), dst); err != nil {
		return "", fmt.Errorf("singbox: binary: replace: %w", err)
	}
	return dst, nil
}

// tempFile records the path before creating it, so crash cleanup can recover it.
func tempFile(p api.Paths, tr api.Traces, pattern string) (string, func(), error) {
	if err := os.MkdirAll(p.Tmp, 0700); err != nil {
		return "", nil, fmt.Errorf("singbox: tmp: %w", err)
	}
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return "", nil, err
	}
	path := filepath.Join(p.Tmp, strings.ReplaceAll(pattern, "*", hex.EncodeToString(nonce)))
	if err := tr.Intent(api.Trace{Kind: "tmp", ID: path, Owner: "singbox", Data: map[string]string{"path": path}}); err != nil {
		return "", nil, err
	}
	release := func() {
		if err := os.Remove(path); err == nil || os.IsNotExist(err) {
			_ = tr.Done("tmp", path)
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", nil, fmt.Errorf("singbox: tmp: %w", err)
	}
	if err = f.Close(); err == nil {
		err = tr.Applied("tmp", path, map[string]string{"path": path}, nil)
	}
	if err != nil {
		release()
		return "", nil, err
	}
	return path, release, nil
}
