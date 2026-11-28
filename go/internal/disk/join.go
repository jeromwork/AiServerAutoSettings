package disk

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"encoding/xml"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"remoteagents/internal/api"
)

// ServerInfo — данные серверного Syncthing (Home/server.json).
type ServerInfo struct {
	DeviceID string `json:"deviceId"`
	SyncPort int    `json:"listen"`
}

// JoinEnv — окружение Join. SSH, Sleep и Generate подменяются в тестах.
type JoinEnv struct {
	Home    string // каталог Диска; state — Home/state
	Bin     string // syncthing
	SSH     func(ctx context.Context, cmd string, stdin []byte) ([]byte, error)
	Log     api.Logger
	Folders []Folder
	Base    string

	DeviceName string                                           // по умолчанию имя хоста
	Sleep      func(ctx context.Context, d time.Duration) error // по умолчанию таймер
	Generate   func(ctx context.Context, bin, state string) error
}

// Паузы повторов регистрации: 60 с, после 3 неудач — 300 с.
const (
	retryShort = 60 * time.Second
	retryLong  = 300 * time.Second
)

// Join: identity -> server -> folders (join.json). Папки принимает этап D, он ставит stage done.
func Join(ctx context.Context, env JoinEnv) (ServerInfo, error) {
	if env.Sleep == nil {
		env.Sleep = sleepCtx
	}
	state := filepath.Join(env.Home, "state")
	if err := os.MkdirAll(env.Home, 0o755); err != nil {
		return ServerInfo{}, err
	}
	id, err := makeIdentity(ctx, &env, state)
	if err != nil {
		return ServerInfo{}, err
	}
	writeStage(env.Home, "identity", "")
	if info, ok := loadServer(env.Home); ok {
		writeStage(env.Home, "folders", info.DeviceID)
		return info, nil
	}
	name := env.DeviceName
	if name == "" {
		name, _ = os.Hostname()
	}
	if name == "" {
		name = "pc"
	}
	var info ServerInfo
	for fails := 0; ; {
		info, err = register(ctx, &env, id, name)
		if err == nil {
			break
		}
		fails++
		if env.Log != nil {
			env.Log.Warn("disk.join.server", "err", err.Error(), "fails", fails)
		}
		pause := retryShort
		if fails > 3 {
			pause = retryLong
		}
		if serr := env.Sleep(ctx, pause); serr != nil {
			return ServerInfo{}, serr
		}
	}
	if err := saveServer(env.Home, info); err != nil {
		return ServerInfo{}, err
	}
	writeStage(env.Home, "server", info.DeviceID)
	writeStage(env.Home, "folders", info.DeviceID)
	return info, nil
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func writeStage(home, stage, serverID string) {
	b, _ := json.Marshal(map[string]any{"stage": stage, "serverId": serverID, "time": time.Now().Unix()})
	_ = writeAtomic(filepath.Join(home, "join.json"), b)
}

func loadServer(home string) (ServerInfo, bool) {
	b, err := os.ReadFile(filepath.Join(home, "server.json"))
	if err != nil {
		return ServerInfo{}, false
	}
	var s ServerInfo
	if json.Unmarshal(b, &s) != nil || !idRe.MatchString(s.DeviceID) || s.SyncPort < 1 || s.SyncPort > 65535 {
		return ServerInfo{}, false
	}
	return s, true
}

func saveServer(home string, s ServerInfo) error {
	b, _ := json.Marshal(s)
	if err := writeAtomic(filepath.Join(home, "server.json"), b); err != nil {
		return err
	}
	return writeAtomic(filepath.Join(home, "server.txt"), []byte(s.DeviceID))
}

var idRe = regexp.MustCompile(`^[A-Z2-7]{7}(?:-[A-Z2-7]{7}){7}$`)

// ---- личность ----

func makeIdentity(ctx context.Context, env *JoinEnv, state string) (string, error) {
	cfg := filepath.Join(state, "config.xml")
	if _, err := os.Stat(cfg); err == nil {
		if needsPrepare(cfg) {
			if err := prepareConfig(state); err != nil {
				return "", err
			}
			if env.Log != nil {
				env.Log.Info("disk.join.identity", "note", "настройки подготовлены")
			}
		}
		return deviceID(filepath.Join(state, "cert.pem"))
	}
	if err := os.MkdirAll(state, 0o755); err != nil {
		return "", err
	}
	gen := env.Generate
	if gen == nil {
		gen = generate
	}
	if err := gen(ctx, env.Bin, state); err != nil {
		return "", fmt.Errorf("не удалось создать личность Диска: %w", err)
	}
	if err := prepareConfig(state); err != nil {
		return "", err
	}
	if env.Log != nil {
		env.Log.Info("disk.join.identity", "note", "создана личность Диска")
	}
	return deviceID(filepath.Join(state, "cert.pem"))
}

func generate(ctx context.Context, bin, state string) error {
	run := func(args ...string) ([]byte, error) {
		c, cancel := context.WithTimeout(ctx, 60*time.Second)
		defer cancel()
		cmd := exec.CommandContext(c, bin, args...)
		return cmd.CombinedOutput()
	}
	out, err := run("generate", "--home", state, "--no-port-probing")
	if err != nil && bytes.Contains(bytes.ToLower(out), []byte("unknown flag")) {
		out, err = run("generate", "--home", state)
	}
	if err != nil {
		return fmt.Errorf("syncthing generate: %w", err)
	}
	return nil
}

func deviceID(certPath string) (string, error) {
	raw, err := os.ReadFile(certPath)
	if err != nil {
		return "", errors.New("не удалось прочитать личность Диска")
	}
	blk, _ := pem.Decode(raw)
	if blk == nil || blk.Type != "CERTIFICATE" || len(blk.Bytes) == 0 {
		return "", errors.New("не удалось прочитать личность Диска")
	}
	return DeviceIDFromDER(blk.Bytes), nil
}

// DeviceIDFromDER — Syncthing device ID (sha256 -> base32 + контрольные Luhn32).
func DeviceIDFromDER(der []byte) string {
	const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	sum := sha256.Sum256(der)
	raw := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(sum[:])
	var sb strings.Builder
	for off := 0; off < 52; off += 13 {
		part := raw[off : off+13]
		factor, total := 1, 0
		for _, ch := range part {
			v := factor * strings.IndexRune(alpha, ch)
			if factor == 1 {
				factor = 2
			} else {
				factor = 1
			}
			total += v/32 + v%32
		}
		sb.WriteString(part)
		sb.WriteByte(alpha[(32-total%32)%32])
	}
	s := sb.String()
	parts := make([]string, 0, 8)
	for i := 0; i < 56; i += 7 {
		parts = append(parts, s[i:i+7])
	}
	return strings.Join(parts, "-")
}

// ---- config.xml ----

type xnode struct {
	XMLName  xml.Name
	Attrs    []xml.Attr `xml:",any,attr"`
	Children []*xnode   `xml:",any"`
	Text     string     `xml:",chardata"`
}

func (n *xnode) find(name string) *xnode {
	for _, c := range n.Children {
		if c.XMLName.Local == name {
			return c
		}
	}
	return nil
}

func (n *xnode) put(name, value string) {
	kept := n.Children[:0]
	for _, c := range n.Children {
		if c.XMLName.Local != name {
			kept = append(kept, c)
		}
	}
	n.Children = append(kept, &xnode{XMLName: xml.Name{Local: name}, Text: value})
}

func readConfig(path string) (*xnode, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var root xnode
	if err := xml.Unmarshal(b, &root); err != nil {
		return nil, err
	}
	return &root, nil
}

func needsPrepare(path string) bool {
	root, err := readConfig(path)
	if err != nil {
		return true
	}
	opts := root.find("options")
	if opts == nil {
		return true
	}
	for _, n := range []string{"globalAnnounceEnabled", "relaysEnabled", "natEnabled"} {
		c := opts.find(n)
		if c == nil || strings.ToLower(strings.TrimSpace(c.Text)) != "false" {
			return true
		}
	}
	return false
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func prepareConfig(state string) error {
	fail := errors.New("не удалось подготовить настройки Диска")
	path := filepath.Join(state, "config.xml")
	root, err := readConfig(path)
	if err != nil {
		return fail
	}
	kept := root.Children[:0]
	for _, c := range root.Children {
		if c.XMLName.Local != "folder" {
			kept = append(kept, c)
		}
	}
	root.Children = kept
	gui, opts := root.find("gui"), root.find("options")
	if gui == nil || opts == nil {
		return fail
	}
	gp, err1 := freePort()
	lp, err2 := freePort()
	for err1 == nil && err2 == nil && lp == gp {
		lp, err2 = freePort()
	}
	if err1 != nil || err2 != nil {
		return fail
	}
	for i := range gui.Attrs {
		if gui.Attrs[i].Name.Local == "tls" {
			gui.Attrs[i].Value = "false"
		}
	}
	if !hasAttr(gui, "tls") {
		gui.Attrs = append(gui.Attrs, xml.Attr{Name: xml.Name{Local: "tls"}, Value: "false"})
	}
	gui.put("address", fmt.Sprintf("127.0.0.1:%d", gp))
	for _, n := range []string{"globalAnnounceEnabled", "localAnnounceEnabled", "relaysEnabled", "natEnabled", "crashReportingEnabled", "startBrowser"} {
		opts.put(n, "false")
	}
	opts.put("listenAddress", fmt.Sprintf("tcp://127.0.0.1:%d", lp))
	opts.put("autoUpgradeIntervalH", "0")
	opts.put("reconnectionIntervalS", "10")
	opts.put("urAccepted", "-1")
	out, err := xml.MarshalIndent(root, "", "  ")
	if err != nil {
		return fail
	}
	if err := writeAtomic(path, append([]byte(xml.Header), out...)); err != nil {
		return errors.New("не удалось сохранить данные Диска")
	}
	return nil
}

func hasAttr(n *xnode, name string) bool {
	for _, a := range n.Attrs {
		if a.Name.Local == name {
			return true
		}
	}
	return false
}

// ---- сервер ----

func serverCommand(id, name string) string {
	j, _ := json.Marshal(map[string]string{"deviceId": id, "deviceName": name})
	payload := base64.StdEncoding.EncodeToString(j)
	return "bash ~/.local/share/remote-disk/server-disk.sh add-device " + payload +
		" >/dev/null && cat ~/.local/share/remote-disk/ports.json && echo && " +
		"~/.local/share/remote-disk/bin/syncthing device-id --home ~/.local/share/remote-disk"
}

func parseServerReply(out []byte) (ServerInfo, error) {
	var info ServerInfo
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "{") {
			var v struct {
				Listen any `json:"listen"`
			}
			if json.Unmarshal([]byte(line), &v) == nil {
				if f, ok := v.Listen.(float64); ok && f == float64(int(f)) && f >= 1 && f <= 65535 {
					info.SyncPort = int(f)
				}
			}
		}
		if idRe.MatchString(line) {
			info.DeviceID = line
		}
	}
	if info.SyncPort == 0 || info.DeviceID == "" {
		return ServerInfo{}, errors.New("сервер не сообщил данные Диска")
	}
	return info, nil
}

func register(ctx context.Context, env *JoinEnv, id, name string) (ServerInfo, error) {
	if env.SSH == nil {
		return ServerInfo{}, errors.New("нет канала к серверу")
	}
	out, err := env.SSH(ctx, serverCommand(id, name), nil)
	if err != nil {
		return ServerInfo{}, fmt.Errorf("сервер не принял ПК: %w", err)
	}
	return parseServerReply(out)
}
