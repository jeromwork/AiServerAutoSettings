package channel

import "remoteagents/internal/api"

// uplink — каркас решателя путей до P13u.
type uplink struct{}

// newUplink — заглушка конструктора из блока B до P13u.
func newUplink(sb api.Singbox, log api.Logger, onSwitch func(path, why string)) *uplink {
	return nil
}
