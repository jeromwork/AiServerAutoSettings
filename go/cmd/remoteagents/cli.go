package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/config"
	"remoteagents/internal/core"
	"remoteagents/internal/platform"
	"remoteagents/internal/supervise"
)

// withBuildInfo добавляет в флаги ядра то, что задано при сборке (-ldflags).
func withBuildInfo(f core.Flags) core.Flags {
	f.Version, f.Build, f.Repo = version, build, releaseRepo
	for _, l := range strings.Split(pubKeys, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			f.Signers = append(f.Signers, l)
		}
	}
	return f
}

// runCLI — короткие подкоманды работают с файлами home и не запускают ядро.
func runCLI(ctx context.Context, name string, args []string) int {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	home := fs.String("home", "", "application data directory")
	passFile := fs.String("password-file", "", "configuration password file")
	fix := fs.Bool("fix", false, "leftovers: remove what was found")
	current := fs.Bool("current", false, "config check: check the saved current generation instead of a file")
	// Подкоманда конфига стоит первым аргументом: config check|apply|revert <файл>.
	var sub string
	if name == "config" && len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		sub, args = args[0], args[1:]
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	plat := platform.Current()
	if *home == "" {
		*home = plat.DefaultHome()
	}
	p := api.NewPaths(*home)
	log := &fake.Logger{}

	switch name {
	case "open", "status":
		b, err := os.ReadFile(filepath.Join(p.State, core.UIURLFile))
		if err != nil {
			fmt.Fprintln(os.Stderr, "core is not running (no webui address)")
			return 1
		}
		url := strings.TrimSpace(string(b))
		fmt.Println(url)
		if name == "open" {
			if err := openURL(url); err != nil {
				fmt.Fprintf(os.Stderr, "open: %v\n", err)
				return 1
			}
		}
		return 0

	case "leftovers":
		c, err := cleanup.New(p, log, plat)
		if err != nil {
			fmt.Fprintf(os.Stderr, "leftovers: %v\n", err)
			return 1
		}
		issues := c.Check(ctx)
		if *fix {
			issues = c.Run(ctx, "startup")
		}
		for _, s := range issues {
			fmt.Println(s)
		}
		if len(issues) > 0 {
			return 1
		}
		return 0

	case "config":
		pass := ""
		if *passFile != "" {
			b, err := os.ReadFile(*passFile)
			if err != nil {
				fmt.Fprintf(os.Stderr, "config: password-file: %v\n", err)
				return 1
			}
			pass = strings.TrimRight(string(b), "\r\n")
		}
		read := func() ([]byte, bool) {
			if fs.NArg() != 1 {
				fmt.Fprintf(os.Stderr, "usage: remoteagents config %s [--password-file F] <file|->\n", sub)
				return nil, false
			}
			var b []byte
			var err error
			if fs.Arg(0) == "-" {
				b, err = io.ReadAll(os.Stdin)
			} else {
				b, err = os.ReadFile(fs.Arg(0))
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "config: %v\n", err)
				return nil, false
			}
			return b, true
		}
		switch sub {
		case "check":
			if *current {
				return checkCurrentConfig(p)
			}
			b, ok := read()
			if !ok {
				return 2
			}
			if _, _, err := config.Open(b, pass); err != nil {
				printConfigErr(err)
				return 1
			}
			fmt.Println("ok")
			return 0
		case "apply":
			b, ok := read()
			if !ok {
				return 2
			}
			gen, err := config.Apply(p, b, pass, log)
			if err != nil {
				printConfigErr(err)
				return 1
			}
			fmt.Println(gen)
			notifyCoreRestart(p)
			return 0
		case "revert":
			if err := config.Revert(p, log); err != nil {
				printConfigErr(err)
				return 1
			}
			fmt.Println("ok")
			notifyCoreRestart(p)
			return 0
		}
		fmt.Fprintln(os.Stderr, "usage: remoteagents config check|apply|revert ...")
		return 2

	case "rollback":
		return cliRollback(ctx, p, log)

	case "update":
		fmt.Fprintln(os.Stderr, "update: run through the web page or the running core (api.Actions.UpdateNow)")
		return 1
	}
	return 1
}

// cliRollback — `remoteagents rollback`: вернуться на предыдущую рабочую версию (и конфиг, который она читает).
// Ядро запущено — просим его через страницу (сторож сам переключает слот); не запущено — правим состояние сами.
func cliRollback(ctx context.Context, p api.Paths, log api.Logger) int {
	if b, err := os.ReadFile(filepath.Join(p.State, core.UIURLFile)); err == nil {
		if u, err := url.Parse(strings.TrimSpace(string(b))); err == nil && u.Host != "" {
			u.Path = "/api/rollback"
			cl := &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{Proxy: nil}}
			if resp, err := cl.Post(u.String(), "application/x-www-form-urlencoded", nil); err == nil {
				defer func() { _ = resp.Body.Close() }()
				var r struct {
					OK    bool   `json:"ok"`
					Error string `json:"error"`
				}
				if json.NewDecoder(resp.Body).Decode(&r) == nil {
					if r.OK {
						fmt.Println("rollback requested: the program restarts on the previous version")
						return 0
					}
					fmt.Fprintln(os.Stderr, "rollback:", r.Error)
					return 1
				}
			}
		}
	}
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "rollback:", err)
		return 1
	}
	to, err := supervise.RollbackOffline(ctx, p, self, version, log)
	if err != nil {
		fmt.Fprintln(os.Stderr, "rollback:", err)
		return 1
	}
	fmt.Println("rolled back to", to, "(takes effect on next start)")
	return 0
}

// checkCurrentConfig — `config check --current` (его вызывает кандидат обновления, update.Stage): новая версия
// обязана прочитать сохранённое текущее поколение. Нет конфига вообще — не ошибка (обновляться можно и без него).
func checkCurrentConfig(p api.Paths) int {
	err := config.CheckCurrent(p)
	if err == nil || errors.Is(err, config.ErrNoConfig) {
		fmt.Println("ok")
		return 0
	}
	printConfigErr(err)
	return 1
}

// notifyCoreRestart просит живое ядро перезапуститься на новый конфиг (событие, не опрос): без этого сторож
// ждёт конца срока switch.json и откатывает его. Нет ядра или оно не ответило за 3 с — только сообщение.
func notifyCoreRestart(p api.Paths) {
	b, err := os.ReadFile(filepath.Join(p.State, core.UIURLFile))
	if err != nil {
		fmt.Fprintln(os.Stderr, "core is not running: the config applies on next start")
		return
	}
	u, err := url.Parse(strings.TrimSpace(string(b)))
	if err != nil || u.Host == "" {
		return
	}
	u.Path = "/api/restart"
	cl := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}
	resp, err := cl.Post(u.String(), "application/x-www-form-urlencoded", nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "core did not answer: restart it to use the new config")
		return
	}
	_ = resp.Body.Close()
}

func printConfigErr(err error) {
	if ce, ok := err.(*config.CheckError); ok {
		for _, pr := range ce.Problems {
			fmt.Fprintf(os.Stderr, "%s %s %s %s\n", pr.Stage, pr.Code, pr.Field, pr.Msg)
		}
		return
	}
	fmt.Fprintln(os.Stderr, err)
}
