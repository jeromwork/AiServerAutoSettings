package vpnrun

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// SetLAN задаёт только клинические домены. Правила появятся после готовности API и DNS.
func (r *Runner) SetLAN(address string, domains []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dnsAddress, r.dnsDomains = address, append([]string(nil), domains...)
}

// Один DNS-запрос (SOA) по TCP, без повторов/системного резолвера. NXDOMAIN тоже ответ DNS.
func dnsProbe(ctx context.Context, address, domain string) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", net.JoinHostPort(address, "53"))
	if err != nil {
		return err
	}
	defer c.Close()
	deadline, _ := ctx.Deadline()
	_ = c.SetDeadline(deadline)
	msg := make([]byte, 12)
	if _, err = rand.Read(msg[:2]); err != nil {
		return err
	}
	msg[2] = 1
	msg[5] = 1
	for _, s := range strings.Split(domain, ".") {
		if len(s) == 0 || len(s) > 63 {
			return fmt.Errorf("invalid DNS label")
		}
		msg = append(msg, byte(len(s)))
		msg = append(msg, s...)
	}
	msg = append(msg, 0, 0, 6, 0, 1)
	wire := make([]byte, 2)
	binary.BigEndian.PutUint16(wire, uint16(len(msg)))
	wire = append(wire, msg...)
	if _, err = c.Write(wire); err != nil {
		return err
	}
	if _, err = io.ReadFull(c, wire[:2]); err != nil {
		return err
	}
	response := make([]byte, int(binary.BigEndian.Uint16(wire[:2])))
	if _, err = io.ReadFull(c, response); err != nil {
		return err
	}
	if len(response) < 12 || response[0] != msg[0] || response[1] != msg[1] || response[2]&0x80 == 0 || (response[3]&15 != 0 && response[3]&15 != 3) {
		return fmt.Errorf("DNS did not answer")
	}
	return nil
}

func (r *Runner) enableDNS(ctx context.Context, gen int) {
	r.dnsMu.Lock()
	defer r.dnsMu.Unlock()
	r.mu.Lock()
	address, domains := r.dnsAddress, append([]string(nil), r.dnsDomains...)
	r.mu.Unlock()
	if address == "" || len(domains) == 0 || !r.current(gen) {
		return
	}
	if err := dnsProbe(ctx, address, domains[0]); err != nil {
		r.Bus.Publish("lan.dns.failed", map[string]any{"error": err.Error()})
		return
	}
	if ctx.Err() != nil || !r.current(gen) {
		return
	}
	r.dnsApplied = true // частичный результат также нужно снять при ошибке.
	if err := r.dnsUpdate(ctx, address, domains); err != nil {
		r.Bus.Publish("lan.dns.failed", map[string]any{"error": err.Error()})
		clearCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if r.dnsUpdate(clearCtx, "", nil) == nil {
			r.dnsApplied = false
		}
		return
	}
	r.Bus.Publish("lan.dns.up", map[string]any{"domains": domains})
}

func (r *Runner) removeDNS(ctx context.Context) error {
	r.dnsMu.Lock()
	defer r.dnsMu.Unlock()
	if !r.dnsApplied {
		return nil
	}
	if err := r.dnsUpdate(ctx, "", nil); err != nil {
		return err
	}
	r.dnsApplied = false
	return nil
}

// ClearDNS — уборка после аварийного завершения; использует ту же выдачу прав, что Install.
func (r *Runner) ClearDNS(ctx context.Context) error { return r.dnsUpdate(ctx, "", nil) }
