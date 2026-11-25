package api

// Ядро → сторож: JSON-строки в stdout ядра (v2: LabMain.OnLine). Других строк в stdout ядро не пишет.
// Сторож → ядро: в stdin {"t":"exit","final":true}; конец stdin = выход.
const (
	MsgGood     = "good"      // {"t":"good","version":"<v>"} первый channel.up: версия проверена
	MsgExit     = "exit"      // {"t":"exit","final":true} ядро завершается по просьбе владельца
	MsgNoConfig = "noconfig"  // {"t":"noconfig"} конфига нет: сторож останавливает таймер молчания
	MsgConfigOK = "config-ok" // {"t":"config-ok"} конфиг появился: таймер молчания снова идёт
)

// Коды выхода ядра (как v2): 0 без MsgExit = падение; 3 = перезапуск (есть Versions/pending.json — новая версия); 4 = память; иное = падение.
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
)

const (
	SilenceUnverifiedSec = 120 // v2 «таймер В»: непроверенная версия обязана сказать good за это время
	MaxFailsGood         = 3
	MaxMemRestarts       = 3
	LongRunSec           = 600
	MaxSlots             = 5
)
