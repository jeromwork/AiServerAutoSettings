package api

import "context"

type Effective struct {
	VPN bool
	LAN bool
}

type RenderContext struct {
	Cfg         *Config
	Mode        Mode
	Instance    string
	ChanPort    int
	ClashPort   int
	ClashSecret string
	GeoIPPath   string
	LANSocks    string
	ExcludeIPs  []string
	Effective   Effective
}

type Part struct {
	Inbounds     []map[string]any
	Outbounds    []map[string]any
	Rules        []map[string]any
	RuleSets     []map[string]any
	RouteExclude []string
}

type Singbox interface {
	Component
	Ready() <-chan struct{}
	ChanAddr() string
	PathNames() []string
	Effective() Effective
	Apply(ctx context.Context, e Effective) error
	Clash(ctx context.Context, method, path string, body, out any) error
}
