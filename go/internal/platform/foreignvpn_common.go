package platform

import "net"

// ForeignVPN — имя чужого VPN-интерфейса: через него ОС ведёт трафик к 1.1.1.1, он не «железный» и не наш; "" — нет.
// Интерфейс определяется одинаково везде: UDP-«соединение» к 1.1.1.1 пакетов не шлёт, но ОС выбирает маршрут и локальный адрес.
func ForeignVPN() string {
	ni := outIface()
	if ni == nil || ni.Flags&net.FlagLoopback != 0 || isOurIface(ni.Name) || isHardwareIface(*ni) {
		return ""
	}
	return ni.Name
}

// ExitIface — имя интерфейса, через который ОС ведёт трафик к addr ("ip:port"); "" — не определён.
// Нужен проверке туннеля: адрес не из РФ и не из исключений должен выходить через наш TUN-адаптер.
func ExitIface(addr string) string {
	if ni := outIfaceTo(addr); ni != nil {
		return ni.Name
	}
	return ""
}

func outIface() *net.Interface { return outIfaceTo("1.1.1.1:53") }

func outIfaceTo(addr string) *net.Interface {
	c, err := net.Dial("udp4", addr)
	if err != nil {
		return nil
	}
	defer c.Close()
	ua, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		return nil
	}
	nis, err := net.Interfaces()
	if err != nil {
		return nil
	}
	for i := range nis {
		as, _ := nis[i].Addrs()
		for _, a := range as {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.Equal(ua.IP) {
				return &nis[i]
			}
		}
	}
	return nil
}
