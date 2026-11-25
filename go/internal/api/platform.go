package api

type AutostartSpec struct {
	Kind    string
	Path    string
	Content string
	Install []string
	Remove  []string
	Enable  []string
	Disable []string
}

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
	RunAsUser(cfg ControlCfg) (string, error)
	NewShell(log Logger, pr Procs, runAs string) Shell
	OpenBrowser(url, runAs string) error
	Autostart(binPath, home string, inst8 string) AutostartSpec
	Interfaces() ([]Iface, error)
}

type LANOps interface {
	ApplyDomains(domains []string, dnsServer string) error
	RemoveAll() error
}
