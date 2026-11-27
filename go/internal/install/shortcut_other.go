//go:build !windows

package install

// На Mac/Linux ярлыков нет (заглушка): только постоянный путь.
func syncShortcut(perm, home string) []string { return nil }
func removeShortcuts(perm string) []string    { return nil }
