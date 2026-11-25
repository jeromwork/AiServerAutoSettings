package api

// Platform exposes only the hooks needed by the core; it runs as the current user.
type Platform interface {
	OS() string
	Arch() string
	NewShell(log Logger, pr Procs) Shell
}
