package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/config"
	"remoteagents/internal/core"
	"remoteagents/internal/platform"
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
			if err := plat.OpenBrowser(url, ""); err != nil {
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
			return 0
		case "revert":
			if err := config.Revert(p, log); err != nil {
				printConfigErr(err)
				return 1
			}
			fmt.Println("ok")
			return 0
		}
		fmt.Fprintln(os.Stderr, "usage: remoteagents config check|apply|revert ...")
		return 2

	case "update":
		fmt.Fprintln(os.Stderr, "update: run through the web page or the running core (api.Actions.UpdateNow)")
		return 1
	}
	return 1
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
