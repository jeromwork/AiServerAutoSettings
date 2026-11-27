package api

type AutostartSpec struct {
	Kind    string   // schtasks | systemd | launchd
	Path    string   // путь файла задания/unit/plist
	Content string   // текст (для schtasks — XML задачи)
	Install []string // argv
	Remove  []string // argv
	Enable  []string // argv включить (без запуска)
	Disable []string // argv выключить
}

type Iface struct {
	Name         string
	Up           bool
	Addrs        []string
	DefaultRoute bool
	Desc         string // описание адаптера (Windows: Description)
	Metric       int    // метрика маршрута по умолчанию (меньше — предпочтительнее)
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
	ExitIface(addr string) string // интерфейс выхода к "ip:port" по таблице маршрутов ОС ("" — не определён)
	ForeignVPN() string           // имя чужого VPN-интерфейса (маршрут к 1.1.1.1), "" — нет
}

// LANOps — платформенные изменения для ЛВС (N2). Каждое — через Traces (Kind nrpt/hosts/dns), только при Mode.AllowsSystemChanges.
type LANOps interface {
	ApplyDomains(domains []string, dnsServer string) error // NRPT (Windows) / resolvectl domain на своём адаптере (Linux) / /etc/resolver (Mac)
	RemoveAll() error
}
