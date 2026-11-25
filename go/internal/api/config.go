package api

import "encoding/json"

// Config is the v2 config plus decrypted runtime values. Raw remains encrypted.
type Config struct {
	Format    string
	Name      string
	Servers   []Server
	Paths     PathsCfg
	VPN       VPNCfg
	LAN       []LANCfg
	Tun       TunCfg
	Happier   HappierCfg
	Forwards  []ForwardCfg
	LanProxy  *LanProxyCfg
	Control   ControlCfg
	Autostart bool
	Update    UpdateCfg
	Disk      json.RawMessage
	Raw       json.RawMessage
	Unknown   []string
	Sections  map[string]json.RawMessage // original top-level sections
	VPNOnly   bool                       // vpn present, server and paths absent
}

type Server struct {
	Host    string
	Port    int
	User    string
	HostKey string
	Key     []byte
}

// EntryRef — элемент paths.entries: строка "имя" или объект; все поля объекта сохраняются.
type EntryRef struct {
	Name    string
	Enabled bool     // нет поля → true; false → путь не строится (paths.py 202–215)
	Kinds   []string // нет поля → все KINDS v2: hy2,hy2obfs,tuic,trojan,reality,shadowtls,ws-direct,ws-cdn
	Extra   map[string]json.RawMessage
}

type PathsCfg struct {
	Entries   []EntryRef
	Relays    []map[string]any // элементы v2 как есть; enabled:false → пропуск (paths.py 202–215)
	Hops      []map[string]any
	CDN       []map[string]any
	WSEntries []map[string]any
	Secrets   map[string]json.RawMessage // имя узла → расшифрованный JSON
	Channel   json.RawMessage            // расшифрованный JSON канала; nil если нет
}

type VPNCfg struct {
	Mode    string // off | auto | only
	Bridges []string
	Direct  VPNDirect
}
type VPNDirect struct {
	Domains []string        // нет поля → RU_DOMAINS v2 (vpn.py 29–31)
	GeoIP   json.RawMessage // как v2 _geoip_cfg
}

type LANCfg struct {
	Name, Host, TestHost string
	Port, TestPort       int
	Share                LANShare
}
type LANShare struct {
	Enabled bool // нет поля share или enabled → true (forward.py 45–47)
	Subnets []string
	Domains []string
}

type TunCfg struct {
	Enabled bool
	Address string
}
type HappierCfg struct{ LocalWeb *LocalWeb }
type LocalWeb struct {
	Enabled          bool
	Port, ServerPort int
}

// ForwardCfg — нормализовано: Listen — только порт (1..65535); формы JSON: число или строка из цифр (как int(f['listen']) v2).
// Invalid items are skipped, as in v2 forward.py.
type ForwardCfg struct {
	Listen int
	ToHost string
	ToPort int
}
type LanProxyCfg struct{ Port int }

// ControlCfg: JSON "control" (bool, absent → false, v2 apply).
type ControlCfg struct {
	Enabled bool
}
type UpdateCfg struct {
	Auto    bool   // JSON update.auto; absent → false
	Channel string // JSON update.channel, preserved when present
}

// Enabled reports explicit section presence; absent sections never start components.
func (c *Config) Enabled(name string) bool {
	if c == nil {
		return false
	}
	v, ok := c.Sections[name]
	if !ok || string(v) == "null" || string(v) == "false" {
		return false
	}
	var obj struct {
		Enabled *bool `json:"enabled"`
	}
	if json.Unmarshal(v, &obj) == nil && obj.Enabled != nil {
		return *obj.Enabled
	}
	return true
}

// Section returns the original parameters without dropping v2 fields.
func (c *Config) Section(name string, dst any) error {
	if c == nil || c.Sections[name] == nil {
		return nil
	}
	return json.Unmarshal(c.Sections[name], dst)
}
