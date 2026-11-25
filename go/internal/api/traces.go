package api

// Журнал следов State/traces.jsonl — write-ahead, одна JSON-строка на запись, fsync файла после каждой записи.
// Фазы одного следа: intent (до изменения) → applied (после, с фактическими значениями) → done (снято).
// Строка, обрезанная аварией (не JSON), игнорируется; intent без applied считается «возможно применено»:
// уборка проверяет факт по Data и снимает, если найдено и принадлежит экземпляру.
type Trace struct {
	Phase    string            `json:"phase"`    // intent | applied | done
	Kind     string            `json:"kind"`     // см. блок C, таблица C1
	ID       string            `json:"id"`       // уникален в пределах Kind и экземпляра
	Instance string            `json:"instance"` // полный id экземпляра (32 hex) — проверка владения всегда по полному
	Owner    string            `json:"owner"`    // компонент
	Data     map[string]string `json:"data"`     // обязательные ключи — таблица C1
	Set      map[string]string `json:"set"`      // что МЫ установили (applied) — сверка перед восстановлением
	Prev     map[string]string `json:"prev"`     // что было до нас
	Keep     bool              `json:"keep"`     // true: не снимать при startup/exit/crash (только uninstall) — autostart
}

type Traces interface {
	Intent(t Trace) error                             // ошибка → изменение НЕ делать
	Applied(kind, id string, data, set map[string]string) error
	Done(kind, id string) error
	Instance() string                                 // 32 hex; системные метки: "ra3-"+Instance()[:8]
}
