package explorer

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"remoteagents/internal/disk"
)

// clientAPI — FolderAPI поверх настоящего REST-клиента Диска.
type clientAPI struct {
	c        *disk.Client
	diskHome string
}

// NewAPI открывает REST локального Syncthing из Home/state/config.xml; Peer берётся из Home/server.txt.
func NewAPI(diskHome string) (FolderAPI, error) {
	c, err := disk.NewClient(filepath.Join(diskHome, "state"))
	if err != nil {
		return nil, err
	}
	a := &clientAPI{c: c, diskHome: diskHome}
	if a.Peer() == "" {
		return nil, errors.New("Сервер Диска ещё не подключён")
	}
	return a, nil
}

func (a *clientAPI) Peer() string {
	b, err := os.ReadFile(filepath.Join(a.diskHome, "server.txt"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(string(b), "\ufeff"))
}

func (a *clientAPI) Request(ctx context.Context, method, path string, body any) ([]byte, error) {
	if method != "GET" && a.Peer() == "" {
		return nil, errors.New("Сервер Диска изменился. Повторите действие")
	}
	var raw json.RawMessage
	if err := a.c.Do(ctx, method, path, body, &raw); err != nil {
		return nil, err
	}
	return raw, nil
}
