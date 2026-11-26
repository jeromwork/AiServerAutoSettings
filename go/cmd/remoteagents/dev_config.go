package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/config"
	"remoteagents/internal/secret"
)

func init() {
	const help = "check <file> <pw> | sample <out> <pw> | apply <home> <file> <pw> | commit <home> | revert <home> | expire <home> [+sec] | status <home> | load <home>"
	for _, name := range []string{"config", "p2"} {
		api.RegisterDev(api.DevCmd{Name: name, Help: help, Run: devConfig})
	}
}

func devConfig(ctx context.Context, args []string) int {
	err := runDevConfig(ctx, args)
	if err != nil {
		var ce *config.CheckError
		if errors.As(err, &ce) {
			for _, p := range ce.Problems {
				fmt.Printf("problem stage=%s code=%s field=%s\n", p.Stage, p.Code, p.Field)
			}
		}
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func runDevConfig(ctx context.Context, a []string) error {
	if ctx.Err() != nil || len(a) == 0 {
		return errors.New("config: usage: see `remoteagents dev` help")
	}
	log := &fake.Logger{}
	need := func(n int) error {
		if len(a) < n {
			return errors.New("config: usage: missing arguments")
		}
		return nil
	}
	switch a[0] {
	case "check":
		if err := need(3); err != nil {
			return err
		}
		data, err := os.ReadFile(a[1])
		if err != nil {
			return errors.New("config: read: cannot read file")
		}
		c, err := config.Check(data, a[2])
		if err != nil {
			return err
		}
		fmt.Printf("ok name=%s server=%s unknown=%v control=%v autostart=%v\n", c.Name, c.Servers[0].Host, c.Unknown, c.Control.Enabled, c.Autostart)
	case "sample":
		if err := need(3); err != nil {
			return err
		}
		return writeSample(a[1], a[2])
	case "apply":
		if err := need(4); err != nil {
			return err
		}
		data, err := os.ReadFile(a[2])
		if err != nil {
			return errors.New("config: read: cannot read file")
		}
		gen, err := config.Apply(api.NewPaths(a[1]), data, a[3], log)
		if err != nil {
			return err
		}
		fmt.Println("applied", gen)
	case "commit":
		if err := need(2); err != nil {
			return err
		}
		p := api.NewPaths(a[1])
		ptr, err := config.ReadPointers(p)
		if err != nil {
			return err
		}
		if err := config.Commit(p, ptr.Current, time.Now()); err != nil {
			return err
		}
		fmt.Println("committed", ptr.Current)
	case "revert":
		if err := need(2); err != nil {
			return err
		}
		return config.Revert(api.NewPaths(a[1]), log)
	case "expire":
		if err := need(2); err != nil {
			return err
		}
		now := time.Now()
		if len(a) > 2 {
			var s int
			fmt.Sscanf(a[2], "+%d", &s)
			now = now.Add(time.Duration(s) * time.Second)
		}
		ch, err := config.Expire(api.NewPaths(a[1]), now, log)
		if err != nil {
			return err
		}
		fmt.Println("expired", ch)
	case "status":
		if err := need(2); err != nil {
			return err
		}
		ptr, err := config.ReadPointers(api.NewPaths(a[1]))
		if err != nil {
			return err
		}
		fmt.Printf("current=%s lastgood=%s", ptr.Current, ptr.LastGood)
		if ptr.Switch != nil {
			fmt.Printf(" switch=%s->%s", ptr.Switch.From, ptr.Switch.To)
		}
		fmt.Println()
	case "load":
		if err := need(2); err != nil {
			return err
		}
		c, gen, err := config.Load(api.NewPaths(a[1]), log)
		if err != nil {
			return err
		}
		fmt.Printf("ok gen=%s keylen=%d secrets=%d\n", gen, len(c.Servers[0].Key), len(c.Paths.Secrets))
	default:
		return errors.New("config: usage: unknown subcommand")
	}
	return nil
}

// writeSample seals a throw-away test config (random-looking fake secrets) for driver checks.
func writeSample(out, password string) error {
	salt := []byte("0123456789abcdef")
	key, err := secret.Derive(password, salt, 1000)
	if err != nil {
		return err
	}
	defer clear(key)
	enc := func(s string) string { v, _ := secret.Seal(key, []byte(s)); return v }
	doc := map[string]any{
		"format": "remoteagents-2", "name": "sample",
		"server": map[string]any{"host": "203.0.113.10", "port": 22, "user": "ra", "hostKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIsample",
			"key": enc("-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----")},
		"paths": map[string]any{"entries": []any{"nl-1"}, "secrets": map[string]any{"nl-1": enc(`{"type":"hy2","password":"fakepw"}`)},
			"channel": enc(`{"host":"203.0.113.10","port":8443}`)},
		"vpn": map[string]any{"mode": "off"}, "control": true, "extra": 1,
		"kdf": map[string]any{"iterations": 1000, "salt": base64.StdEncoding.EncodeToString(salt)}, "check": enc("remoteagents"),
	}
	b, _ := json.MarshalIndent(doc, "", " ")
	if err := os.WriteFile(out, append(b, '\n'), 0o600); err != nil {
		return err
	}
	fmt.Println("sample written:", strings.TrimSpace(out))
	return nil
}
