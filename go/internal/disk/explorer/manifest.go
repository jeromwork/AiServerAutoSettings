package explorer

import (
	"encoding/json"
	"os"
	"strings"
)

func lowerPath(p string) string { return strings.ToLower(p) }

func readManifest(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var v []string
	if json.Unmarshal(b, &v) != nil {
		return nil
	}
	return v
}

func writeManifest(path string, paths []string) {
	if paths == nil {
		paths = []string{}
	}
	b, _ := json.Marshal(paths)
	if cur, err := os.ReadFile(path); err == nil && string(cur) == string(b) {
		return
	}
	_ = writeFileAtomic(path, b)
}
