//go:build !windows

package main

// prepareConsole — только Windows: exe без окна (-H windowsgui) подключает консоль родителя / прячет консоль ядра.
func prepareConsole(string) {}
