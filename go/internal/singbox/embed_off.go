//go:build !singbox_embed

package singbox

// Dev builds carry no sing-box; installBinary falls back to the pinned download.
var embeddedBin []byte
