package vpnrun

import (
	"context"
	"net"
)

// resolvectl меняет только DNS нашего интерфейса, ~domain не становится DNS по умолчанию.
func (r *Runner) dnsUpdate(ctx context.Context, address string, domains []string) error {
	if _, err := net.InterfaceByName("RA2-LAN"); err != nil && len(domains) == 0 {
		return nil
	}
	if len(domains) == 0 {
		_, err := runContext(ctx, "sudo", "-n", "/usr/bin/resolvectl", "revert", "RA2-LAN")
		return err
	}
	if _, err := runContext(ctx, "sudo", "-n", "/usr/bin/resolvectl", "default-route", "RA2-LAN", "no"); err != nil {
		return err
	}
	if _, err := runContext(ctx, "sudo", "-n", "/usr/bin/resolvectl", "dns", "RA2-LAN", address); err != nil {
		return err
	}
	args := []string{"-n", "/usr/bin/resolvectl", "domain", "RA2-LAN"}
	for _, d := range domains {
		args = append(args, "~"+d)
	}
	_, err := runContext(ctx, "sudo", args...)
	return err
}
