//go:build darwin

package platform

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// ForeignVPN — `route -n get 1.1.1.1` (разово по событию сети): интерфейс utun*/ipsec*/ppp*/tun*/tap* и не наш.
func ForeignVPN() string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/sbin/route", "-n", "get", "1.1.1.1").Output()
	if err != nil {
		return ""
	}
	return parseDarwinRouteIface(string(out))
}

func parseDarwinRouteIface(out string) string {
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if !strings.HasPrefix(l, "interface:") {
			continue
		}
		name := strings.TrimSpace(strings.TrimPrefix(l, "interface:"))
		if isOurIface(name) {
			return ""
		}
		for _, p := range []string{"utun", "ipsec", "ppp", "tun", "tap"} {
			if strings.HasPrefix(name, p) {
				return name
			}
		}
		return ""
	}
	return ""
}
