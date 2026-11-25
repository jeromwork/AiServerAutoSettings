package singbox

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const assetLimit = 128 << 20

type asset struct{ OS, Arch, URL, SHA256, BinPath string }

// Install only the platform asset authenticated by the pinned archive digest.
func installBinary(ctx context.Context, binDir, lockPath string) (string, error) {
	data, err := os.ReadFile(lockPath)
	if err != nil {
		return "", fmt.Errorf("singbox: lock: cannot read lock")
	}
	var lock struct {
		Version string
		Assets  []asset
		Tags    any
	}
	if json.Unmarshal(data, &lock) != nil {
		return "", fmt.Errorf("singbox: lock: invalid JSON")
	}
	var selected asset
	for _, a := range lock.Assets {
		if a.OS == runtime.GOOS && a.Arch == runtime.GOARCH {
			selected = a
			break
		}
	}
	digest, err := hex.DecodeString(selected.SHA256)
	if err != nil || len(digest) != sha256.Size || selected.BinPath == "" {
		return "", fmt.Errorf("singbox: lock: missing platform asset or digest")
	}
	if err = os.MkdirAll(binDir, 0700); err != nil {
		return "", fmt.Errorf("singbox: binary: create directory: %w", err)
	}
	archive, err := os.CreateTemp(binDir, ".ra-core-archive-*")
	if err != nil {
		return "", fmt.Errorf("singbox: binary: temporary archive: %w", err)
	}
	defer func() { _ = archive.Close(); _ = os.Remove(archive.Name()) }()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, selected.URL, nil)
	if err != nil {
		return "", fmt.Errorf("singbox: download: invalid URL")
	}
	client := &http.Client{Timeout: 25 * time.Second}
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
	tmp, err := os.CreateTemp(binDir, ".ra-core-*")
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
	name := "ra-core"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	dst := filepath.Join(binDir, name)
	if err = os.Rename(tmp.Name(), dst); err != nil {
		return "", fmt.Errorf("singbox: binary: replace: %w", err)
	}
	return dst, nil
}
