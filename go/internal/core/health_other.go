//go:build !linux

package core

func openFDs() int { return -1 }
