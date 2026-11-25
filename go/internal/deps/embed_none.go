//go:build !bundle

package deps

// Development builds keep the v2 runtime/bin.zip fallback.
var embeddedBundle []byte
