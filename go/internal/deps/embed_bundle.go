//go:build bundle

package deps

import _ "embed"

//go:embed bin.zip
var embeddedBundle []byte
