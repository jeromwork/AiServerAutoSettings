package platform

import (
	"net/netip"
	"testing"
)

func TestParseWinRoutePrint(t *testing.T) {
	out := `Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1    192.168.1.5     25
          0.0.0.0        128.0.0.0         10.9.0.1       10.9.0.2      6
         12.0.0.0        255.0.0.0         On-link       10.9.0.2      6
      203.0.113.5  255.255.255.255      192.168.1.1    192.168.1.5     25
`
	names := map[netip.Addr]string{netip.MustParseAddr("192.168.1.5"): "Wi-Fi", netip.MustParseAddr("10.9.0.2"): "HappTun"}
	rs := parseWinRoutePrint(out, func(a netip.Addr) string { return names[a] })
	if len(rs) != 4 {
		t.Fatalf("%v", rs)
	}
	if l, via := ForeignMaxPrefix(rs); l != 8 || via != "HappTun" {
		t.Fatalf("l=%d via=%s", l, via)
	}
}

func TestParseProcNetRoute(t *testing.T) {
	data := "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n" +
		"eth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n" +
		"tun0\t0000000C\t00000000\t0001\t0\t0\t0\t000000FF\t0\t0\t0\n" // 12.0.0.0/8
	rs := parseProcNetRoute(data)
	if len(rs) != 2 || rs[1].Prefix.String() != "12.0.0.0/8" {
		t.Fatalf("%v", rs)
	}
	if l, via := ForeignMaxPrefix(rs); l != 8 || via != "tun0" {
		t.Fatalf("l=%d via=%s", l, via)
	}
}

func TestParseDarwinNetstat(t *testing.T) {
	out := `Destination        Gateway            Flags           Netif Expire
default            192.168.1.1        UGScg             en0
0/1                10.9.0.1           UGScg           utun4
12                 link#12            UCS             utun4
127                127.0.0.1          UCS               lo0
`
	rs := parseDarwinNetstat(out)
	if len(rs) != 4 {
		t.Fatalf("%v", rs)
	}
	if l, via := ForeignMaxPrefix(rs); l != 8 || via != "utun4" {
		t.Fatalf("l=%d via=%s", l, via)
	}
}

func TestForeignMaxPrefixIgnoresOursPrivateAndHost(t *testing.T) {
	p := netip.MustParsePrefix
	rs := []Route{{p("0.0.0.0/1"), "ra3-abcd1234-vpn"}, {p("10.1.0.0/16"), "HappTun"}, {p("203.0.113.5/32"), "HappTun"}, {p("1.2.3.0/24"), "Ethernet"}}
	if l, _ := ForeignMaxPrefix(rs); l != 0 {
		t.Fatalf("l=%d", l)
	}
}
