package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/supervise"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "supervise",
		Help: "supervise driver: sim <home> [--fast]",
		Run:  runDevSupervise,
	})
	api.RegisterDev(api.DevCmd{
		Name: "p8",
		Help: "alias for supervise driver: sim <home> [--fast]",
		Run:  runDevSupervise,
	})
}

type simLogger struct{}

func (s *simLogger) Info(event string, kv ...any) {
	fmt.Printf("[supervise info] %s\n", event)
}

func (s *simLogger) Warn(event string, kv ...any) {
	fmt.Printf("[supervise warn] %s\n", event)
}

func (s *simLogger) Error(event string, kv ...any) {
	fmt.Printf("[supervise error] %s\n", event)
}

func (s *simLogger) With(component string) api.Logger {
	return s
}

func (s *simLogger) Secret(value string) {}

func (s *simLogger) Writer(stream, source string) io.WriteCloser {
	return discardCloser{}
}

func (s *simLogger) Drops() int64 { return 0 }

type discardCloser struct{}

func (discardCloser) Write(p []byte) (int, error) { return len(p), nil }
func (discardCloser) Close() error                { return nil }

func writeExecutableScript(path, unixContent, winContent string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	content := strings.Replace(unixContent, "#!/bin/sh\n", "#!/bin/sh\nif [ \"$1\" = version ]; then echo embedded; exit 0; fi\n", 1)
	if runtime.GOOS == "windows" {
		content = winContent
	}
	return os.WriteFile(path, []byte(content), 0755)
}

func getExeName() string {
	if runtime.GOOS == "windows" {
		return "remoteagents.exe"
	}
	return "remoteagents"
}

func runDevSupervise(ctx context.Context, args []string) int {
	if runtime.GOOS == "windows" {
		fmt.Fprintln(os.Stderr, "supervise: sim requires Unix sh scripts")
		return 1
	}
	if len(args) == 0 {
		fmt.Println("usage: remoteagents dev supervise sim <home> [--fast]")
		return 1
	}

	if args[0] != "sim" {
		fmt.Fprintf(os.Stderr, "unknown dev supervise command: %s\n", args[0])
		return 1
	}

	fast := false
	var homeDir string
	for _, arg := range args[1:] {
		if arg == "--fast" {
			fast = true
		} else if !strings.HasPrefix(arg, "-") && homeDir == "" {
			homeDir = arg
		}
	}

	if homeDir == "" {
		tmp, err := os.MkdirTemp("", "ra3-supervise-sim-*")
		if err != nil {
			fmt.Fprintf(os.Stderr, "cannot create temp dir: %v\n", err)
			return 1
		}
		defer func() { _ = os.RemoveAll(tmp) }()
		homeDir = tmp
	}

	if err := os.MkdirAll(homeDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "cannot create home dir: %v\n", err)
		return 1
	}

	logger := &simLogger{}
	exeName := getExeName()

	// Scenario 1: «непроверенная → lastGood»
	fmt.Println("=== Scenario 1: непроверенная → lastGood ===")
	home1 := filepath.Join(homeDir, "sim1")
	p1 := api.NewPaths(home1)

	v1Exe := filepath.Join(p1.Versions, "v1", exeName)
	v1Unix := "#!/bin/sh\necho '{\"t\":\"good\",\"version\":\"v1\"}'\necho '{\"t\":\"alive\"}'\necho '{\"t\":\"exit\",\"final\":true}'\nexit 0\n"
	v1Win := "@echo off\r\necho {\"t\":\"good\",\"version\":\"v1\"}\r\necho {\"t\":\"exit\",\"final\":true}\r\nexit /b 0\r\n"
	if err := writeExecutableScript(v1Exe, v1Unix, v1Win); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 1 setup failed: %v\n", err)
		return 1
	}

	v2Exe := filepath.Join(p1.Versions, "v2", exeName)
	v2Unix := "#!/bin/sh\nexit 1\n"
	v2Win := "@echo off\r\nexit /b 1\r\n"
	if err := writeExecutableScript(v2Exe, v2Unix, v2Win); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 1 setup failed: %v\n", err)
		return 1
	}

	self1 := filepath.Join(home1, "mock-self")
	if runtime.GOOS == "windows" {
		self1 += ".bat"
	}
	if err := writeExecutableScript(self1, v1Unix, v1Win); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 1 setup failed: %v\n", err)
		return 1
	}

	state1JSON := `{"current":"v2","lastGood":"v1","embeddedSeen":"embedded"}`
	if err := os.WriteFile(filepath.Join(p1.Versions, "state.json"), []byte(state1JSON), 0600); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 1 state setup failed: %v\n", err)
		return 1
	}

	superArgs1 := []string{"--home", home1}
	if fast {
		superArgs1 = append(superArgs1, "--fast")
	}
	if code := supervise.Run(ctx, p1, logger, nil, self1, api.Mode{Safe: true}, superArgs1); code != api.SupExitDone {
		fmt.Fprintf(os.Stderr, "scenario 1 returned code %d, expected %d\n", code, api.SupExitDone)
		return 1
	}

	// Scenario 2: «3 падения → stopped»
	fmt.Println("=== Scenario 2: 3 падения → stopped ===")
	home2 := filepath.Join(homeDir, "sim2")
	p2 := api.NewPaths(home2)

	badExe := filepath.Join(p2.Versions, "bad", exeName)
	badUnix := "#!/bin/sh\nexit 1\n"
	badWin := "@echo off\r\nexit /b 1\r\n"
	if err := writeExecutableScript(badExe, badUnix, badWin); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 2 setup failed: %v\n", err)
		return 1
	}

	self2 := filepath.Join(home2, "mock-self")
	if runtime.GOOS == "windows" {
		self2 += ".bat"
	}
	if err := writeExecutableScript(self2, badUnix, badWin); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 2 setup failed: %v\n", err)
		return 1
	}

	state2JSON := `{"current":"bad","lastGood":"bad","embeddedSeen":"embedded","failsGood":0}`
	if err := os.WriteFile(filepath.Join(p2.Versions, "state.json"), []byte(state2JSON), 0600); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 2 state setup failed: %v\n", err)
		return 1
	}

	superArgs2 := []string{"--home", home2}
	if fast {
		superArgs2 = append(superArgs2, "--fast")
	}
	if code := supervise.Run(ctx, p2, logger, nil, self2, api.Mode{Safe: true}, superArgs2); code != api.SupExitDone {
		fmt.Fprintf(os.Stderr, "scenario 2 returned code %d, expected %d\n", code, api.SupExitDone)
		return 1
	}

	// Scenario 3: «тишина 120 с» (или «тишина 3 с» при --fast)
	fmt.Println("=== Scenario 3: тишина ===")
	home3 := filepath.Join(homeDir, "sim3")
	p3 := api.NewPaths(home3)

	flagFile := filepath.Join(home3, "invoked.flag")
	silentExe := filepath.Join(p3.Versions, "silent", exeName)
	silentUnix := fmt.Sprintf("#!/bin/sh\nif [ ! -f '%s' ]; then\n  touch '%s'\n  sleep 300\nelse\n  echo '{\"t\":\"good\",\"version\":\"silent\"}'\n  echo '{\"t\":\"alive\"}'\necho '{\"t\":\"exit\",\"final\":true}'\n  exit 0\nfi\n", flagFile, flagFile)
	silentWin := fmt.Sprintf("@echo off\r\nif not exist \"%s\" (\r\n  type nul > \"%s\"\r\n  timeout /t 30 /nobreak >nul\r\n) else (\r\n  echo {\"t\":\"good\",\"version\":\"silent\"}\r\n  echo {\"t\":\"exit\",\"final\":true}\r\n  exit /b 0\r\n)\r\n", flagFile, flagFile)
	if err := writeExecutableScript(silentExe, silentUnix, silentWin); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 3 setup failed: %v\n", err)
		return 1
	}

	self3 := filepath.Join(home3, "mock-self")
	if runtime.GOOS == "windows" {
		self3 += ".bat"
	}
	self3Unix := "#!/bin/sh\necho '{\"t\":\"good\",\"version\":\"embedded\"}'\necho '{\"t\":\"alive\"}'\necho '{\"t\":\"exit\",\"final\":true}'\nexit 0\n"
	self3Win := "@echo off\r\necho {\"t\":\"good\",\"version\":\"embedded\"}\r\necho {\"t\":\"exit\",\"final\":true}\r\nexit /b 0\r\n"
	if err := writeExecutableScript(self3, self3Unix, self3Win); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 3 setup failed: %v\n", err)
		return 1
	}

	state3JSON := `{"current":"silent","lastGood":"","embeddedSeen":"embedded"}`
	if err := os.WriteFile(filepath.Join(p3.Versions, "state.json"), []byte(state3JSON), 0600); err != nil {
		fmt.Fprintf(os.Stderr, "scenario 3 state setup failed: %v\n", err)
		return 1
	}

	// For test speed, scenario 3 always uses fast unless caller explicitly passed another home without fast
	superArgs3 := []string{"--home", home3, "--fast"}
	if code := supervise.Run(ctx, p3, logger, nil, self3, api.Mode{Safe: true}, superArgs3); code != api.SupExitDone {
		fmt.Fprintf(os.Stderr, "scenario 3 returned code %d, expected %d\n", code, api.SupExitDone)
		return 1
	}

	fmt.Println("=== ALL SUPERVISE SIMULATIONS OK ===")
	return 0
}
