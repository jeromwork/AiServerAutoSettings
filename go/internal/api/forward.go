package api

type Exposed struct {
	Name       string `json:"name"`
	ServerPort int    `json:"serverPort"`
	PCPort     int    `json:"pcPort"`
	Err        string `json:"err,omitempty"`
}

type Forwarder interface {
	Component
	Expose(name string, serverPort, pcPort int) (Exposed, error) // pcPort 0 — прежний порт этого имени или serverPort; поиск от want до min(want+20, 65535), кроме занятых/служебных (как v2)
	Unexpose(name string) error
	List() []Exposed
	InternalSocks() string // "127.0.0.1:port" SOCKS5 поверх канала для sing-box LAN (не из конфига); "" в Safe
}
