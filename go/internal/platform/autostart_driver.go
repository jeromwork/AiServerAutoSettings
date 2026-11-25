package platform

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// RunAutostartDev only writes a temporary specification; it never installs it.
func RunAutostartDev(ctx context.Context, args []string) (code int) {
	if len(args) != 2 || args[0] != "autostart" || args[1] != runtime.GOOS {
		fmt.Fprintln(os.Stderr, "usage: dev platform autostart "+runtime.GOOS)
		return 2
	}
	bin, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	dir, err := os.MkdirTemp("", "ra3-autostart-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer func() {
		if err := os.RemoveAll(dir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			code = 1
		}
	}()
	spec := Current().Autostart(bin, filepath.Join(dir, "home"), "12345678")
	path := filepath.Join(dir, filepath.Base(spec.Path))
	if err := os.WriteFile(path, []byte(spec.Content), 0600); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Print(spec.Content)
	if runtime.GOOS == "linux" {
		cmd := exec.CommandContext(ctx, "systemd-analyze", "verify", path)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	fmt.Println("OK: autostart " + runtime.GOOS)
	return 0
}
