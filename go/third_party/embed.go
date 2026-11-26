// Package thirdparty carries the pinned third-party manifest inside the exe.
package thirdparty

import _ "embed"

// SingboxLock is singbox.lock.json: versions, URLs, sha256 and the mirror base.
//
//go:embed singbox.lock.json
var SingboxLock []byte
