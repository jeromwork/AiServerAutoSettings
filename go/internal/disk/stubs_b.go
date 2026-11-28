package disk

// Временные заглушки этапа B строго по контракту (config.go — этап A, join.go — этап C).
// При слиянии файл удалить.

import (
	"context"
	"encoding/json"

	"remoteagents/internal/api"
)

type Folder struct {
	ID   string
	Path string
}

type Config struct {
	Home     string
	Base     string
	Folders  []Folder
	Enabled  *bool
	SyncPort int
}

func ParseConfig(raw json.RawMessage, topSyncPort int) (Config, error) {
	return Config{SyncPort: topSyncPort}, nil
}

type JoinEnv struct {
	Home    string
	Bin     string
	SSH     func(ctx context.Context, cmd string, stdin []byte) ([]byte, error)
	Log     api.Logger
	Folders []Folder
	Base    string
}

type ServerInfo struct {
	DeviceID string
	SyncPort int
}

func Join(ctx context.Context, env JoinEnv) (ServerInfo, error) {
	return ServerInfo{}, context.Canceled
}
