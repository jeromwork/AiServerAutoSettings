//go:build !linux

package platform

import "context"

// SweepVPNLock — уборка остатков правил «только через наш адрес»; вне Linux правила держит сам процесс/ОС по-другому, ничего не делаем.
func SweepVPNLock(context.Context) error { return nil }
