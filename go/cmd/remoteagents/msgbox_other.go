//go:build !windows

package main

// showError — на не-Windows достаточно stderr.
func showError(string) {}

// showInfo — на не-Windows достаточно stdout.
func showInfo(string) {}
