package platform

import (
	"strconv"
	"strings"

	"remoteagents/internal/api"
)

// parseScutilProxy — разбор вывода `scutil --proxy` (macOS): HTTPEnable/HTTPProxy/HTTPPort, HTTPS*, SOCKS*, ProxyAutoConfig*.
func parseScutilProxy(out string) api.SysProxy {
	kv := map[string]string{}
	for _, ln := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(ln, " : ")
		if ok {
			kv[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	res := api.SysProxy{Supported: true}
	var parts []string
	for _, p := range [][2]string{{"http", "HTTP"}, {"https", "HTTPS"}, {"socks", "SOCKS"}} {
		if kv[p[1]+"Enable"] == "1" && kv[p[1]+"Proxy"] != "" {
			h := kv[p[1]+"Proxy"]
			if port, err := strconv.Atoi(kv[p[1]+"Port"]); err == nil && port > 0 {
				h += ":" + strconv.Itoa(port)
			}
			parts = append(parts, p[0]+"="+h)
		}
	}
	if len(parts) > 0 {
		res.Enabled, res.Server = true, strings.Join(parts, ";")
	}
	if kv["ProxyAutoConfigEnable"] == "1" {
		res.Enabled, res.PAC = true, kv["ProxyAutoConfigURLString"]
	}
	return res
}
