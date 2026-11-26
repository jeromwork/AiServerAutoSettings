//go:build !singbox_embed

package singbox

// Default builds carry no sing-box; installBinary finds or downloads the pinned one.
var embeddedBin []byte
