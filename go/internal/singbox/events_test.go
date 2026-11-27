package singbox

import "testing"

func TestTapClassify(t *testing.T) {
	var got []string
	tp := &tap{on: func(k string) { got = append(got, k) }}
	tp.Write([]byte("INFO inbound/direct[in-chan]: ok\nERROR [1 2s] connection: open using outbound/vless[x]: dial tcp: i/o timeout\nINFO network changed, upda"))
	tp.Write([]byte("ted default interface\nWARN network changed\n"))
	if len(got) != 3 || got[0] != EvOutboundError || got[2] != EvNetworkChanged {
		t.Fatalf("got %v", got)
	}
}
