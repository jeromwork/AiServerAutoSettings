package procs

import (
	"fmt"
	"os"
	"strings"
)

// processStart returns /proc start ticks: cleanup (steps_linux) compares them directly.
func processStart(pid int) (string, error) {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(stat)[strings.LastIndexByte(string(stat), ')')+1:])
	if len(fields) < 20 {
		return "", fmt.Errorf("short stat")
	}
	return fields[19], nil
}
