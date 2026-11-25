// Package deps pins imported-but-not-directly-used dependencies so they appear in go.mod.
package deps

import (
	_ "github.com/hiddeco/sshsig"
	_ "golang.org/x/crypto/ssh"
	_ "golang.org/x/sys/execabs"
)
