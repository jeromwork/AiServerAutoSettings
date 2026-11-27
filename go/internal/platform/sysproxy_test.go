package platform

import "testing"

func TestParseScutilProxy(t *testing.T) {
	p := parseScutilProxy("<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 7890\n  HTTPProxy : 127.0.0.1\n  HTTPSEnable : 0\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : http://x/pac\n}")
	if !p.Enabled || p.Server != "http=127.0.0.1:7890" || p.PAC != "http://x/pac" {
		t.Fatalf("%+v", p)
	}
	if q := parseScutilProxy("HTTPEnable : 0"); q.Enabled {
		t.Fatal("off")
	}
}
