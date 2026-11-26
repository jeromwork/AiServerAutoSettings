//go:build singbox_embed

package singbox

import _ "embed"

// build.sh puts the verified sing-box of the target platform here.
//
//go:embed embedded/sing-box.bin
var embeddedBin []byte
