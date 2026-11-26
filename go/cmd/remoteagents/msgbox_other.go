//go:build !windows

package main

// showError — на не-Windows достаточно stderr.
func showError(string) {}
