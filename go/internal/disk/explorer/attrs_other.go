//go:build !windows

package explorer

import "os"

func getAttrs(string, os.FileInfo) Attrs { return Attrs{} }
func setAttrs(string, Attrs) error       { return nil }

// NewNotifier — на не-Windows уведомлять Проводник некому.
func NewNotifier() Notifier { return nopNotifier{} }

type nopNotifier struct{}

func (nopNotifier) Changed(string) {}

// AssociationsChanged — no-op.
func AssociationsChanged() {}

// NewRegStore — на не-Windows реестра нет: меню не ставится.
func NewRegStore() RegStore { return nopStore{} }

type nopStore struct{}

func (nopStore) Exists(string) bool                 { return false }
func (nopStore) Read(string, string) string         { return "" }
func (nopStore) Write(string, string, string) error { return nil }
func (nopStore) DeleteTree(string) error            { return nil }

// RecycleBin — на не-Windows Корзины Диска нет: «Оставить только на сервере» недоступно.
func RecycleBin(string) error { return ErrRecycle }
