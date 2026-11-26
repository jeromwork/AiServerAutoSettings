package cleanup

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"remoteagents/internal/api"
)

type Cleaner struct {
	mu       sync.Mutex
	p        api.Paths
	log      api.Logger
	plat     api.Platform
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

	// Serialize creation across processes; rename alone can overwrite another creator.
	unlock, err := currentPlatformSteps.lock(filepath.Join(p.State, "instance.lock"))
	if err != nil {
		return nil, fmt.Errorf("cleanup: instance-busy: %w", err)
	}
	defer unlock()

	instPath := filepath.Join(p.State, "instance")
	if id, err := readInstanceFile(instPath); err == nil {
		return &Cleaner{p: p, log: log, plat: plat, instance: id}, nil
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}

	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	id := hex.EncodeToString(raw)

	tmpPath := filepath.Join(p.State, fmt.Sprintf("instance.tmp.%d.%s", os.Getpid(), id[:8]))
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	if _, err := f.WriteString(id + "\n"); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("cleanup: instance: %w", err)
	}
	if err := os.Rename(tmpPath, instPath); err != nil {
		_ = os.Remove(tmpPath)
		if existingID, rErr := readInstanceFile(instPath); rErr == nil {
			id = existingID
		} else {
			return nil, fmt.Errorf("cleanup: instance: rename: %w", err)
		}
	}
	if dir, err := os.Open(p.State); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	return &Cleaner{p: p, log: log, plat: plat, instance: id}, nil
}

func readInstanceFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(string(b))
	raw, err := hex.DecodeString(id)
	if err != nil || len(raw) != 16 || id != strings.ToLower(id) {
		return "", fmt.Errorf("invalid identifier")
	}
	return id, nil
}

// Home — корень home экземпляра (для следов процессов).
func (c *Cleaner) Home() string { return c.p.Home }
