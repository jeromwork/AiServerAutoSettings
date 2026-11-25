package api

// Mode — режим запуска. Задаётся флагами сторожа, сохраняется в State/mode.json при первом старте этого home,
// передаётся ядру аргументами и НЕ меняется ни ConfigApply, ни обновлением, ни откатом.
// Сменить можно только: остановить сторож и запустить с другими флагами.
type Mode struct {
	Safe      bool `json:"safe"`      // никаких системных изменений: без TUN/VPN/LAN, DNS/NRPT/hosts/proxy/firewall, автозапуска, статических пробросов
	NoTun     bool `json:"noTun"`     // без TUN (VPN и LAN выключены), остальное разрешено
	NoChannel bool `json:"noChannel"` // без ssh-канала (для пакетных проверок)
	NoSingbox bool `json:"noSingbox"` // канал напрямую (ssh-direct), ra-core не запускать
}

// AllowsSystemChanges — можно ли менять систему (сеть, автозапуск, прокси).
func (m Mode) AllowsSystemChanges() bool { return !m.Safe }
func (m Mode) AllowsTun() bool           { return !m.Safe && !m.NoTun && !m.NoSingbox }
