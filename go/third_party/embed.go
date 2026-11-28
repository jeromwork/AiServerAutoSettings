// Package thirdparty carries the pinned third-party manifest inside the exe.
package thirdparty

import _ "embed"

// SingboxLock is singbox.lock.json: versions, URLs, sha256 and the mirror base.
//
//go:embed singbox.lock.json
var SingboxLock []byte

// DiskLock is disk.lock.json: pinned Syncthing(tray) build for the Disk (url, sha256, binSha256).
//
//go:embed disk.lock.json
var DiskLock []byte
