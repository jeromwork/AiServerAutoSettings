package disk

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
)

type server struct {
	DeviceID string `json:"deviceId"`
	Listen   int    `json:"listen"`
}
type progress struct {
	Stage    string   `json:"stage"`
	ServerID string   `json:"serverId,omitempty"`
	Accepted []string `json:"accepted,omitempty"`
	Waiting  []string `json:"waiting,omitempty"`
	Time     int64    `json:"time,omitempty"`
}

func deviceID(path string) (string, error) {
	b, e := os.ReadFile(path)
	if e != nil {
		return "", errors.New("Не удалось прочитать личность Диска.")
	}
	block, _ := pem.Decode(b)
	if block == nil || block.Type != "CERTIFICATE" || len(block.Bytes) == 0 {
		return "", errors.New("Не удалось прочитать личность Диска.")
	}
	hash := sha256.Sum256(block.Bytes)
	raw := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(hash[:])
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	checked := ""
	for offset := 0; offset < 52; offset += 13 {
		part := raw[offset : offset+13]
		factor, total := 1, 0
		for _, c := range part {
			value := factor * strings.IndexRune(alphabet, c)
			factor = 3 - factor
			total += value/32 + value%32
		}
		checked += part + string(alphabet[(32-total%32)%32])
	}
	var groups []string
	for i := 0; i < 56; i += 7 {
		groups = append(groups, checked[i:i+7])
	}
	return strings.Join(groups, "-"), nil
}
func freePort() (string, error) {
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		return "", e
	}
	defer l.Close()
	return strconv.Itoa(l.Addr().(*net.TCPAddr).Port), nil
}
func (d *Disk) command(ctx context.Context, name, path string, args []string, timeout time.Duration) ([]byte, []byte, int, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var stdout, stderr bytes.Buffer
	p, e := d.o.Procs.Start(ctx, api.ProcSpec{Name: name, Path: path, Args: args, Stdout: &stdout, Stderr: &stderr})
	if e != nil {
		return nil, nil, -1, e
	}
	select {
	case <-p.Done():
	case <-ctx.Done():
		stop, c := context.WithTimeout(context.Background(), 6*time.Second)
		defer c()
		_ = p.Stop(stop)
		return nil, nil, -1, ctx.Err()
	}
	return stdout.Bytes(), stderr.Bytes(), p.ExitCode(), nil
}
func (d *Disk) makeIdentity(ctx context.Context) (string, error) {
	state := filepath.Join(d.home, "state")
	if !exists(filepath.Join(state, "config.xml")) {
		if e := os.MkdirAll(state, 0700); e != nil {
			return "", e
		}
		args := []string{"syncthing", "generate", "--home", state, "--no-port-probing"}
		out, errout, code, e := d.command(ctx, "disk.identity", d.o.Exe, args, 60*time.Second)
		if e == nil && code != 0 && bytes.Contains(bytes.ToLower(append(out, errout...)), []byte("unknown flag")) {
			_, _, code, e = d.command(ctx, "disk.identity", d.o.Exe, args[:len(args)-1], 60*time.Second)
		}
		if e != nil || code != 0 {
			return "", errors.New("Не удалось создать личность Диска.")
		}
	}
	root, e := loadXML(state)
	if e != nil {
		return "", errSettings
	}
	options := root.child("options")
	needs := options == nil
	for _, name := range []string{"globalAnnounceEnabled", "relaysEnabled", "natEnabled"} {
		if options == nil || strings.ToLower(options.text(name)) != "false" {
			needs = true
		}
	}
	if needs {
		gui, e := freePort()
		if e != nil {
			return "", e
		}
		listen, e := freePort()
		if e != nil {
			return "", e
		}
		for listen == gui {
			listen, e = freePort()
			if e != nil {
				return "", e
			}
		}
		if e = prepare(state, gui, listen); e != nil {
			return "", e
		}
	}
	return deviceID(filepath.Join(state, "cert.pem"))
}
func serverCommand(id, name string) string {
	payload, _ := jsonBytes(map[string]string{"deviceId": id, "deviceName": name})
	return "bash ~/.local/share/remote-disk/server-disk.sh add-device " + base64.StdEncoding.EncodeToString(payload) + " >/dev/null && cat ~/.local/share/remote-disk/ports.json && echo && ~/.local/share/remote-disk/bin/syncthing device-id --home ~/.local/share/remote-disk"
}

var devicePattern = regexp.MustCompile(`^[A-Z2-7]{7}(?:-[A-Z2-7]{7}){7}$`)

func (d *Disk) register(ctx context.Context, id string) (server, error) {
	ctx, cancel := context.WithTimeout(ctx, 150*time.Second)
	defer cancel()
	name := d.o.Config.Name
	if name == "" {
		name = os.Getenv("COMPUTERNAME")
	}
	var out, errout bytes.Buffer
	code, e := d.o.Channel.Exec(ctx, serverCommand(id, name), nil, &out, &errout)
	if e != nil || code != 0 {
		return server{}, errors.New("Не удалось зарегистрировать ПК на сервере Диска.")
	}
	var reply server
	for _, line := range strings.Split(out.String(), "\n") {
		line = strings.TrimSpace(line)
		var ports struct {
			Listen int `json:"listen"`
		}
		if readBytes([]byte(line), &ports) == nil && ports.Listen > 0 && ports.Listen <= 65535 {
			reply.Listen = ports.Listen
		}
		if devicePattern.MatchString(line) {
			reply.DeviceID = line
		}
	}
	if reply.DeviceID == "" || reply.Listen == 0 {
		return server{}, errors.New("Сервер не сообщил данные Диска.")
	}
	return reply, nil
}
func (d *Disk) join(ctx context.Context) error {
	state := filepath.Join(d.home, "state")
	path := filepath.Join(d.home, "join.json")
	if exists(filepath.Join(state, "config.xml")) && !exists(path) {
		return nil
	}
	if e := writeJSON(path, progress{Stage: "identity"}); e != nil {
		return e
	}
	id, e := d.makeIdentity(ctx)
	if e != nil {
		return e
	}
	if e = writeJSON(path, progress{Stage: "server"}); e != nil {
		return e
	}
	reply, e := d.register(ctx, id)
	if e != nil {
		return e
	}
	if e = writeJSON(filepath.Join(d.home, "server.json"), reply); e != nil {
		return e
	}
	if e = writeFile(filepath.Join(d.home, "server.txt"), []byte(reply.DeviceID)); e != nil {
		return e
	}
	saved := filepath.Join(defaultHome(), "base.txt")
	if os.Getenv("LOCALAPPDATA") == "" {
		h, _ := os.UserHomeDir()
		saved = filepath.Join(h, "AppData", "Local", "RemoteDisk", "base.txt")
	}
	if !exists(saved) {
		if e = writeFile(saved, []byte(d.base)); e != nil {
			return e
		}
	}
	return writeJSON(path, progress{Stage: "folders", ServerID: reply.DeviceID})
}
