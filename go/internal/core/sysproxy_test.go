package core

import "testing"

func TestParseProxyServer(t *testing.T) {
	for in, want := range map[string]string{
		"127.0.0.1:7890": "http://127.0.0.1:7890",
		"http=127.0.0.1:7890;https=127.0.0.1:7891": "http://127.0.0.1:7891",
		"socks=127.0.0.1:1080":                     "socks5://127.0.0.1:1080",
		"http://10.0.0.1:8080":                     "http://10.0.0.1:8080",
		"":                                         "",
		"ftp=1.2.3.4:21":                           "",
	} {
		u := parseProxyServer(in)
		got := ""
		if u != nil {
			got = u.String()
		}
		if got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
	if !isLocalHost("127.0.0.1") || isLocalHost("10.0.0.1") {
		t.Fatal("isLocalHost")
	}
}
