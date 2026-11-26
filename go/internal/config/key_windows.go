//go:build windows

package config

import (
	"errors"
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows: the derived key is protected with DPAPI (current user) in key.dpapi.
func writeKey(genDir string, key []byte) error {
	if len(key) == 0 {
		return errors.New("config: key: empty")
	}
	in := windows.DataBlob{Size: uint32(len(key)), Data: &key[0]}
	var out windows.DataBlob
	if err := windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	blob := append([]byte(nil), unsafe.Slice(out.Data, out.Size)...)
	return writeFile(filepath.Join(genDir, "key.dpapi"), blob, 0o600)
}

func readKey(genDir string) ([]byte, error) {
	blob, err := os.ReadFile(filepath.Join(genDir, "key.dpapi"))
	if err != nil {
		return nil, err
	}
	if len(blob) == 0 {
		return nil, errors.New("config: key: empty")
	}
	in := windows.DataBlob{Size: uint32(len(blob)), Data: &blob[0]}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}
