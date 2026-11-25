package api

type Exposed struct {
	Name       string `json:"name"`
	ServerPort int    `json:"serverPort"`
	PCPort     int    `json:"pcPort"`
	Err        string `json:"err,omitempty"`
}

type Forwarder interface {
	Component
	Expose(name string, serverPort, pcPort int) (Exposed, error)
	Unexpose(name string) error
	List() []Exposed
	InternalSocks() string
}
