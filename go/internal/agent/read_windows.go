package agent

import (
	"errors"
	"os"
	"strings"
)

func openRegular(path string) (*os.File, error) {
	return openRegularFile(path, os.O_RDONLY)
}

func openRegularFile(path string, flag int) (*os.File, error) {
	// Named pipes and devices are not files and can block during open. Refuse
	// Windows device namespaces before asking the OS for file metadata.
	normalized := strings.ToLower(strings.ReplaceAll(path, "/", `\`))
	if strings.HasPrefix(normalized, `\\.\`) || strings.HasPrefix(normalized, `\\?\`) || strings.HasPrefix(normalized, `\??\`) {
		return nil, errors.New("agent: file: device namespace is not supported")
	}
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, errors.New("agent: file: regular file required")
	}
	return os.OpenFile(path, flag, 0)
}
