package cleanup

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"remoteagents/internal/api"
)

type Cleaner struct {
	mu       sync.Mutex
	p        api.Paths
	instance string
}

var _ api.Traces = (*Cleaner)(nil)

func New(p api.Paths, log api.Logger, plat api.Platform) (*Cleaner, error) {
	home, err := filepath.Abs(p.Home)
	if err != nil || p.Home == "" || filepath.Dir(home) == home {
		return nil, fmt.Errorf("cleanup: home: invalid home")
	}
	if p.State != filepath.Join(home, "state") || p.Tmp != filepath.Join(home, "tmp") {
		return nil, fmt.Errorf("cleanup: paths: expected absolute home paths")
	}
	if err = os.MkdirAll(p.State, 0700); err != nil {
		return nil, fmt.Errorf("cleanup: state: %w", err)
	}
	f, err := os.OpenFile(filepath.Join(p.State, "instance"), os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	created := err == nil
	if os.IsExist(err) {
		f, err = os.Open(filepath.Join(p.State, "instance"))
	}
	if err != nil {
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	defer func() { _ = f.Close() }()
	b := make([]byte, 33)
	n, err := f.ReadAt(b, 0)
	if err != nil && err != io.EOF {
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	if created {
		raw := make([]byte, 16)
		if _, err = rand.Read(raw); err == nil {
			_, err = f.WriteAt([]byte(hex.EncodeToString(raw)), 0)
		}
		if err == nil {
			err = f.Sync()
		}
		if err != nil {
			return nil, fmt.Errorf("cleanup: instance: %w", err)
		}
		n, err = f.ReadAt(b, 0)
		if err != nil && err != io.EOF {
			return nil, fmt.Errorf("cleanup: instance: %w", err)
		}
	}
	id := strings.TrimSpace(string(b[:n]))
	if raw, e := hex.DecodeString(id); e != nil || len(raw) != 16 || id != strings.ToLower(id) {
		return nil, fmt.Errorf("cleanup: instance: invalid identifier")
	}
	return &Cleaner{p: p, instance: id}, nil
}
