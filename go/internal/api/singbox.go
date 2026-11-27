package api

import "context"

// Effective — желаемое состояние частей ВСЕГДА целиком (нельзя выключить VPN, случайно сбросив LAN).
type Effective struct {
	VPN bool
	LAN bool
}

// RenderContext — всё, что нужно генератору. Заполняет singbox.New/Apply, части только читают.
type RenderContext struct {
	Cfg          *Config
	Mode         Mode
	Instance     string // 32 hex; адаптеры: "ra3-"+Instance[:8]+"-vpn" / "-lan"
	ChanPort     int
	ClashPort    int
	ClashSecret  string
	GeoIPPath    string   // State/geoip-ru.srs ("" — нет файла)
	LANSocks     string   // "127.0.0.1:port" внутреннего SOCKS (Forwarder.InternalSocks); "" — LAN недоступен
	DefaultIface string   // физический внешний интерфейс (route.default_interface); "" — auto_detect_interface
	ExcludeIPs   []string // IP сервера, входов, мостов, DNS ПК — route_exclude_address (vpn.py 273–291)
	Effective    Effective
	VPNBlock     bool // VPN перекрывает интернет (этап 3a, vpn.lockExit): всё, что не исключено, отклоняется; свой процесс программы идёт через vpn-out для проверок
	VPNSplit     int  // нарезка route_address VPN блоками /N (этап 1b); 0/1 — стандартные 0/1+128/1
}

// Part — вклад части в конфиг sing-box.
type Part struct {
	Inbounds     []map[string]any
	Outbounds    []map[string]any
	Rules        []map[string]any // вставляются ПОСЛЕ правил канала (порядок — блок C, C3)
	RuleSets     []map[string]any
	RouteExclude []string
	Final        string // route.final ("" — не задавать); VPN: vpn-out
	FindProcess  bool   // route.find_process (правила process_name)
}

type Singbox interface {
	Component
	Ready() <-chan struct{}
	ChanAddr() string
	PathNames() []string // имена путей селектора chan
	Effective() Effective
	Apply(ctx context.Context, e Effective) error // .new → check → замена → перезапуск; ошибка check — прежнее остаётся
	Clash(ctx context.Context, method, path string, body, out any) error
}
