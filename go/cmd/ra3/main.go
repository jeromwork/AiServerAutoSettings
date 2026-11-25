// Command ra3 is the server-side CLI for RemoteAgents 3.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const usageText = `ra3 — серверная утилита RemoteAgents 3

Использование:
  ra3 [глобальные флаги] <команда> [аргументы команды]

Команды:
  status [ПК]                                   получить статус ПК (/status)
  push [--version V] [--deadline S] <ПК> [файл] собрать/отправить обновление на ПК и ждать переподключения
  log [-f] [-n N] [--interval D] [ПК]           просмотр журнала ПК (-f: следить за новыми строками)
  rollback [ПК]                                 запросить откат на предыдущую версию (/rollback)
  version                                       показать версию утилиты
  help                                          показать эту справку

Глобальные флаги:
  --pc <имя>         имя ПК (по умолчанию: последний подключавшийся)
  --state-dir <путь> директория файлов состояния (по умолчанию ~/.local/state/ra-lab или RA_STATE_DIR)
`

var version = "3.0.0-dev"

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := run(ctx, os.Args[1:]); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	var globalPC string
	var stateDir string

	var cmdArgs []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--pc" && i+1 < len(args) {
			globalPC = args[i+1]
			i++
		} else if strings.HasPrefix(arg, "--pc=") {
			globalPC = strings.TrimPrefix(arg, "--pc=")
		} else if arg == "--state-dir" && i+1 < len(args) {
			stateDir = args[i+1]
			i++
		} else if strings.HasPrefix(arg, "--state-dir=") {
			stateDir = strings.TrimPrefix(arg, "--state-dir=")
		} else if arg == "-h" || arg == "--help" || arg == "help" {
			fmt.Print(usageText)
			return nil
		} else if arg == "version" || arg == "--version" {
			fmt.Printf("ra3 version %s\n", version)
			return nil
		} else {
			cmdArgs = args[i:]
			break
		}
	}

	if stateDir == "" {
		stateDir = defaultStateDir()
	}

	if len(cmdArgs) == 0 {
		fmt.Print(usageText)
		return nil
	}

	subcmd := cmdArgs[0]
	rest := cmdArgs[1:]

	switch subcmd {
	case "status":
		if len(rest) > 1 || (len(rest) == 1 && strings.HasPrefix(rest[0], "-")) {
			return fmt.Errorf("ra3: status [ПК]")
		}
		pc := globalPC
		if len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
			pc = rest[0]
		}
		return cmdStatus(ctx, stateDir, pc)

	case "push":
		fs := flag.NewFlagSet("push", flag.ContinueOnError)
		fs.SetOutput(os.Stderr)
		var customVer string
		var deadlineSec int
		fs.StringVar(&customVer, "version", "", "версия для X-Version")
		fs.IntVar(&deadlineSec, "deadline", 150, "таймаут ожидания в секундах")
		if err := fs.Parse(rest); err != nil {
			return err
		}

		positional := fs.Args()
		limit := 2
		if globalPC != "" {
			limit = 1
		}
		if len(positional) > limit {
			return fmt.Errorf("ra3: push <ПК> [файл]")
		}
		pc := globalPC
		var binaryFile string

		if len(positional) > 0 {
			if pc == "" {
				pc = positional[0]
				if len(positional) > 1 {
					binaryFile = positional[1]
				}
			} else {
				binaryFile = positional[0]
			}
		}

		if pc == "" {
			return fmt.Errorf("ra3 push: необходимо указать ПК: ra3 push <ПК> [файл]")
		}

		return cmdPush(ctx, stateDir, pc, binaryFile, customVer, deadlineSec)

	case "log":
		var follow bool
		var count int = 200
		var interval time.Duration = time.Second
		var pc string = globalPC

		for i := 0; i < len(rest); i++ {
			arg := rest[i]
			if arg == "-f" || arg == "--follow" {
				follow = true
			} else if arg == "-n" && i+1 < len(rest) {
				c, err := strconv.Atoi(rest[i+1])
				if err != nil || c <= 0 {
					return fmt.Errorf("ra3: неверное число строк")
				}
				count = c
				i++
			} else if strings.HasPrefix(arg, "-n=") {
				c, err := strconv.Atoi(strings.TrimPrefix(arg, "-n="))
				if err != nil || c <= 0 {
					return fmt.Errorf("ra3: неверное число строк")
				}
				count = c
			} else if arg == "--interval" && i+1 < len(rest) {
				d, err := time.ParseDuration(rest[i+1])
				if err != nil || d <= 0 {
					return fmt.Errorf("ra3: неверный интервал")
				}
				interval = d
				i++
			} else if strings.HasPrefix(arg, "--interval=") {
				d, err := time.ParseDuration(strings.TrimPrefix(arg, "--interval="))
				if err != nil || d <= 0 {
					return fmt.Errorf("ra3: неверный интервал")
				}
				interval = d
			} else if !strings.HasPrefix(arg, "-") && pc == "" {
				pc = arg
			} else {
				return fmt.Errorf("ra3: неверный аргумент log: %s", arg)
			}
		}

		return cmdLog(ctx, stateDir, pc, follow, count, interval)

	case "rollback":
		if len(rest) > 1 || (len(rest) == 1 && strings.HasPrefix(rest[0], "-")) {
			return fmt.Errorf("ra3: rollback [ПК]")
		}
		pc := globalPC
		if len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
			pc = rest[0]
		}
		return cmdRollback(ctx, stateDir, pc)

	default:
		return fmt.Errorf("ra3: неизвестная команда %q. Используйте 'ra3 help' для списка команд.", subcmd)
	}
}
