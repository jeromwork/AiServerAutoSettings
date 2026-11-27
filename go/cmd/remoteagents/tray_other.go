//go:build !windows

package main

import "context"

// startTray — значок в трее есть только в Windows.
func startTray(context.Context, string, func()) func() { return func() {} }

// trayURL — адрес страницы для значка (в других ОС не нужен).
func trayURL(string) {}
