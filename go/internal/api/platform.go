package api

type Iface struct {
	Name         string
	Up           bool
	Addrs        []string
	DefaultRoute bool
}

type Platform interface {
	OS() string
	Arch() string
	DefaultHome() string
	IsAdmin() bool
	NewShell(log Logger, pr Procs) Shell
	OpenBrowser(url string) error
	Interfaces() ([]Iface, error)
}

// LANOps — платформенные изменения для ЛВС (N2). Каждое — через Traces (Kind nrpt/hosts/dns), только при Mode.AllowsSystemChanges.
type LANOps interface {
	ApplyDomains(domains []string, dnsServer string) error // NRPT (Windows) / resolvectl domain на своём адаптере (Linux) / /etc/resolver (Mac)
	RemoveAll() error
}
