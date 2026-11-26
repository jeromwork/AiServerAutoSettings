//go:build !windows

package config

import (
	"os"
	"path/filepath"
)

// Unix: the derived key is a file with mode 600 inside the generation (the config dir is the owner's).
func writeKey(genDir string, key []byte) error {
	return writeFile(filepath.Join(genDir, "key"), key, 0o600)
}

func readKey(genDir string) ([]byte, error) { return os.ReadFile(filepath.Join(genDir, "key")) }
