package api

import (
	"context"
	"io"
)

const VersionRe = `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`

// Версия: "3.0.<build>", build — git rev-list --count HEAD; сравнение — по build (целое).
type Release struct {
	Version string
	Build   int
	OS      string
	Arch    string
	URL     string
	SHA256  string
}

// Updater: только загрузка и проверка. Переключение слота делает вызывающий (core) под LockOp.
type Updater interface {
	Check(ctx context.Context) (*Release, error)
	Fetch(ctx context.Context, r Release) (candidate string, err error)                                   // файл в Tmp: sha + подпись sshsig; при ошибке файл удалён
	Stage(ctx context.Context, candidate, version string) error                                           // проверки кандидата (блок C, C5) → versions/<v>/ → pending.json
	ReceiveDev(ctx context.Context, body io.Reader, sha256, version string) (candidate string, err error) // ≤100 МиБ, только sha
}
