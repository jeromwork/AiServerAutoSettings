package cleanup

// В v2 уборки для macOS нет: нечего убирать (интерфейс utun исчезает вместе с процессом).
func (c *Cleaner) steps(mode string) []step { return nil }
