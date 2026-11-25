package api

import "io"

// Потоки: файл <Logs>/lab-<поток>-<N>.jsonl; N только растёт (как v2 journal._roll), хранится 4 последних по 5 МиБ.
const (
	StreamCore   = "core"
	StreamSup    = "sup"
	StreamSB     = "sb"
	StreamShell  = "shell"
	StreamUpdate = "update"
	StreamBoot   = "boot"
)

// Logger. Маска (как v2 journal.register/mask): секрет регистрируется целиком и каждой строкой (splitlines);
// берутся значения длиной ≥2 после strip; ≥4 — замена подстроки на ***; 2–3 — только целым токеном
// (?<![\w-])s(?![\w-]); до 2000 секретов; применяется ко ВСЕМ потокам процесса (общий маскировщик).
type Logger interface {
	Info(event string, kv ...any)
	Warn(event string, kv ...any)
	Error(event string, kv ...any)
	With(component string) Logger
	Secret(value string)
	Writer(stream, source string) io.WriteCloser // построчно, с маской, поле src=source
	Drops() int64                                // сколько строк потеряно (ошибка записи/квота)
}
