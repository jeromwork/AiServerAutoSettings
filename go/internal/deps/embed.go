package deps

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// installBundle supplies the archive that the v2 launcher put in runtime/bin.zip.
func installBundle(path string) error {
	if len(embeddedBundle) == 0 {
		return nil
	}
	sum := sha256.Sum256(embeddedBundle)
	if got, err := hash(path); err == nil && got == hex.EncodeToString(sum[:]) {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", embeddedBundle, 0644); err != nil {
		return err
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		_ = os.Remove(path + ".tmp")
		return err
	}
	return nil
}
