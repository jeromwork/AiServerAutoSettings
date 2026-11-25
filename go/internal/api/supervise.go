package api

const (
	MsgGood     = "good"
	MsgAlive    = "alive"
	MsgExit     = "exit"
	MsgRollback = "rollback"
)

const (
	ExitOK      = 0
	ExitRestart = 3
	ExitMemory  = 4
)

const (
	SupExitDone    = 0
	SupExitRunning = 10
)

const (
	SilenceUnverifiedSec = 120
	SilenceVerifiedSec   = 120
	MaxFailsGood         = 3
	MaxFailsBoot         = 3
	MaxMemRestarts       = 3
	LongRunSec           = 600
	MaxSlots             = 5
	ConfigSwitchSec      = 120
)
