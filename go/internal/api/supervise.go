package api

// Ядро → сторож: JSON-строки в stdout ядра. Других строк в stdout ядро не пишет.
const (
	MsgGood     = "good"     // {"t":"good","version":"<v>"}
	MsgAlive    = "alive"    // {"t":"alive"} каждые 10 с
	MsgExit     = "exit"     // {"t":"exit","final":true}
	MsgRollback = "rollback" // {"t":"rollback","reason":"…"}
)

// Коды выхода ядра (как v2): 0 без MsgExit = падение; 3 = перезапуск/новый слот; 4 = память; иное = падение.
const (
	ExitOK      = 0
	ExitRestart = 3
	ExitMemory  = 4
)

// Коды выхода СТОРОЖА (для автозапуска): 0 — финальный выход или остановка по лимиту (автозапуск НЕ перезапускает);
// 10 — уже запущен (не перезапускать); иное — авария сторожа (systemd Restart=on-failure, launchd KeepAlive.SuccessfulExit=false,
// schtasks RestartOnFailure — перезапускают).
const (
	SupExitDone    = 0
	SupExitRunning = 10
	// SupExitHandover — хорошая версия стала текущей и записана на постоянный путь: сторож вышел, запускающий код стартует новый сторож с этого пути.
	SupExitHandover = 11
)

const (
	SilenceUnverifiedSec = 120
	SilenceVerifiedSec   = 120
	MaxFailsGood         = 3
	MaxFailsBoot         = 3 // v3: падения embedded без lastGood до остановки
	MaxMemRestarts       = 3
	LongRunSec           = 600
	MaxSlots             = 5
	ConfigSwitchSec      = 120
)
