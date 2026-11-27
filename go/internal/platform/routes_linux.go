//go:build linux

package platform

import "os"

func readRoutes() ([]Route, error) {
	data, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return nil, err
	}
	return parseProcNetRoute(string(data)), nil
}
