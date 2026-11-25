package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/journal"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "journal",
		Help: "journal stress test: dev journal stress <home>",
		Run:  runDevJournal,
	})
	api.RegisterDev(api.DevCmd{
		Name: "p3",
		Help: "journal stress test alias: dev p3 stress <home>",
		Run:  runDevJournal,
	})
}

func runDevJournal(ctx context.Context, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev journal stress <home>")
		return 1
	}

	switch args[0] {
	case "stress":
		home := ""
		if len(args) > 1 {
			home = args[1]
		}
		if home == "" {
			tmpDir, err := os.MkdirTemp("", "ra3-journal-stress-*")
			if err != nil {
				fmt.Fprintf(os.Stderr, "failed to create temp dir: %v\n", err)
				return 1
			}
			home = tmpDir
			defer func() { _ = os.RemoveAll(tmpDir) }()
		}

		paths := api.NewPaths(home)
		j, err := journal.New(paths, api.StreamCore, journal.Options{
			MaxBytes: 5 * 1024 * 1024,
			Keep:     4,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "journal.New failed: %v\n", err)
			return 1
		}

		targetToken := "TopSecretPassword123"
		j.Secret(targetToken)

		// Each record is ~1100 bytes. 6200 records ~= 6.8 MiB, exceeding the 5 MiB rotation threshold.
		defer func() { _ = j.Close() }()
		padding := strings.Repeat("A", 1000)
		for i := 0; i < 6200; i++ {
			if ctx.Err() != nil {
				return 1
			}
			j.Info("stress.event", "val", "password="+targetToken, "seq", i, "pad", padding)
		}
		if err := j.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "journal.Close failed: %v\n", err)
			return 1
		}

		// Verify files
		logsDir := paths.Logs
		entries, err := os.ReadDir(logsDir)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to read logs dir: %v\n", err)
			return 1
		}

		foundCore2 := false
		coreFileCount := 0
		tokenLeakCount := 0
		maskedFound := false

		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			name := entry.Name()
			if strings.HasPrefix(name, "lab-core-") && strings.HasSuffix(name, ".jsonl") {
				coreFileCount++
				if name == "lab-core-2.jsonl" {
					foundCore2 = true
				}
				data, err := os.ReadFile(filepath.Join(logsDir, name))
				if err != nil {
					fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", name, err)
					return 1
				}
				if bytes.Contains(data, []byte(targetToken)) {
					tokenLeakCount++
				}
				if bytes.Contains(data, []byte("***")) {
					maskedFound = true
				}
			}
		}

		if !foundCore2 {
			fmt.Fprintln(os.Stderr, "FAILED: lab-core-2.jsonl was not created")
			return 1
		}
		if coreFileCount > 4 {
			fmt.Fprintf(os.Stderr, "FAILED: coreFileCount (%d) > 4\n", coreFileCount)
			return 1
		}
		if tokenLeakCount > 0 {
			fmt.Fprintf(os.Stderr, "FAILED: token leaked in %d files\n", tokenLeakCount)
			return 1
		}
		if !maskedFound {
			fmt.Fprintln(os.Stderr, "FAILED: '***' not found in files")
			return 1
		}

		fmt.Printf("OK: lab-core-2.jsonl created, files=%d <= 4, secret leaks=0, mask=*** verified\n", coreFileCount)
		return 0

	default:
		fmt.Fprintf(os.Stderr, "unknown dev journal command: %s\n", args[0])
		return 1
	}
}
