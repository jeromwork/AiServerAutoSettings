package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
)

const keepGens = 5

var genRe = regexp.MustCompile(`^gen-([0-9]+)$`)

type switchFile struct {
	Op       string `json:"op"`
	From     string `json:"from"`
	To       string `json:"to"`
	Started  string `json:"started"`
	Deadline string `json:"deadline"`
}

// GenDir / PrivateDir: layout of one generation (gen "current" is not resolved here).
func GenDir(p api.Paths, gen string) string     { return filepath.Join(p.Config, gen) }
func PrivateDir(p api.Paths, gen string) string { return filepath.Join(GenDir(p, gen), "private") }

func readLine(path string) (string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	s := strings.TrimSpace(string(b))
	if err == nil && s != "" && !genRe.MatchString(s) {
		return "", fmt.Errorf("config: bad-pointer: %s", filepath.Base(path))
	}
	return s, err
}

func writeLine(p api.Paths, name, val string) error {
	path := filepath.Join(p.Config, name)
	if val == "" {
		return removeDurable(path)
	}
	return writeFile(path, []byte(val+"\n"), 0o600)
}

// ReadPointers reads current, lastgood and switch.json. If switch.to == lastgood (crash between
// writing lastgood and removing the switch, C7) the switch is dropped.
func ReadPointers(p api.Paths) (Pointers, error) {
	var r Pointers
	var err error
	if r.Current, err = readLine(filepath.Join(p.Config, "current")); err != nil {
		return r, err
	}
	if r.LastGood, err = readLine(filepath.Join(p.Config, "lastgood")); err != nil {
		return r, err
	}
	b, err := os.ReadFile(filepath.Join(p.Config, "switch.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return r, err
	}
	var sf switchFile
	if json.Unmarshal(b, &sf) != nil || !genRe.MatchString(sf.To) {
		return r, errors.New("config: bad-switch")
	}
	if sf.To == r.LastGood && r.LastGood != "" {
		_ = removeDurable(filepath.Join(p.Config, "switch.json"))
		return r, nil
	}
	st, e1 := time.Parse(time.RFC3339Nano, sf.Started)
	dl, e2 := time.Parse(time.RFC3339Nano, sf.Deadline)
	if e1 != nil || e2 != nil {
		return r, errors.New("config: bad-switch")
	}
	r.Switch = &Switch{Op: sf.Op, From: sf.From, To: sf.To, Started: st, Deadline: dl}
	return r, nil
}

func writeSwitch(p api.Paths, s Switch) error {
	b, _ := json.Marshal(switchFile{Op: s.Op, From: s.From, To: s.To,
		Started: s.Started.UTC().Format(time.RFC3339Nano), Deadline: s.Deadline.UTC().Format(time.RFC3339Nano)})
	return writeFile(filepath.Join(p.Config, "switch.json"), append(b, '\n'), 0o600)
}

type genInfo struct {
	name string
	n    int
}

func listGens(p api.Paths) []genInfo {
	ents, _ := os.ReadDir(p.Config)
	var out []genInfo
	for _, e := range ents {
		if m := genRe.FindStringSubmatch(e.Name()); m != nil && e.IsDir() {
			n, _ := strconv.Atoi(m[1])
			out = append(out, genInfo{e.Name(), n})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].n < out[j].n })
	return out
}

// prune removes interrupted builds (*.new) and old generations beyond keepGens. It never removes
// current, lastgood, switch.from or switch.to (C7).
func prune(p api.Paths, ptr Pointers, log api.Logger) {
	ents, _ := os.ReadDir(p.Config)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "gen-") && strings.HasSuffix(e.Name(), ".new") {
			_ = os.RemoveAll(filepath.Join(p.Config, e.Name()))
		}
	}
	keep := map[string]bool{ptr.Current: true, ptr.LastGood: true}
	if ptr.Switch != nil {
		keep[ptr.Switch.From], keep[ptr.Switch.To] = true, true
	}
	gens := listGens(p)
	for i := 0; i < len(gens) && len(gens) > keepGens; {
		if keep[gens[i].name] {
			i++
			continue
		}
		_ = os.RemoveAll(filepath.Join(p.Config, gens[i].name))
		log.Info("config.prune", "gen", gens[i].name)
		gens = append(gens[:i], gens[i+1:]...)
	}
}

// SchemaVersion — формат поколения конфига, который эта сборка читает и пишет. Новая версия, меняющая формат
// gen-N, увеличивает число; более старая сборка такое поколение не читает (ErrNewerSchema), а сторож при откате
// версии возвращает конфиг на последнее поколение, которое откатываемая версия читает (CompatRollback).
const SchemaVersion = 1

// ErrNewerSchema: поколение записано более новой версией программы.
var ErrNewerSchema = errors.New("config: newer-schema")

type genMeta struct {
	Schema int `json:"schema"`
}

// GenSchema — схема поколения из meta.json; поколения до появления схемы (нет файла) — схема 1.
func GenSchema(p api.Paths, gen string) int {
	b, err := os.ReadFile(filepath.Join(GenDir(p, gen), "meta.json"))
	if err != nil {
		return 1
	}
	var m genMeta
	if json.Unmarshal(b, &m) != nil || m.Schema < 1 {
		return 1
	}
	return m.Schema
}

// CompatRollback: версия, читающая схему maxSchema, становится рабочей (откат версии). Если текущее поколение
// записано более новой схемой — current переносится на lastgood, а при его непригодности на самое новое
// проверенное (good) поколение с подходящей схемой; ожидающее переключение (switch.json) снимается.
// Возвращает новое поколение или "" если менять ничего не нужно. Вызывать под LockOp.
func CompatRollback(p api.Paths, maxSchema int, log api.Logger) (string, error) {
	if log == nil {
		log = nopLog{}
	}
	ptr, err := ReadPointers(p)
	if err != nil || ptr.Current == "" || GenSchema(p, ptr.Current) <= maxSchema {
		return "", err
	}
	usable := func(g string) bool {
		if g == "" || GenSchema(p, g) > maxSchema {
			return false
		}
		_, err := os.Stat(filepath.Join(GenDir(p, g), "active.json"))
		return err == nil
	}
	target := ""
	if usable(ptr.LastGood) {
		target = ptr.LastGood
	} else {
		gens := listGens(p)
		for i := len(gens) - 1; i >= 0; i-- {
			if _, err := os.Stat(filepath.Join(GenDir(p, gens[i].name), "good")); err == nil && usable(gens[i].name) {
				target = gens[i].name
				break
			}
		}
	}
	if err := removeDurable(filepath.Join(p.Config, "switch.json")); err != nil {
		return "", err
	}
	if err := writeLine(p, "current", target); err != nil {
		return "", err
	}
	log.Warn("config.compat-rollback", "from", ptr.Current, "to", target, "maxSchema", maxSchema)
	return target, nil
}

// Apply builds gen-N+1 completely, then writes switch.json and moves current (plan §5.2).
// A crash before current moves leaves the new generation unused. ErrPending while a switch exists.
func Apply(p api.Paths, data []byte, password string, log api.Logger) (string, error) {
	if log == nil {
		log = nopLog{}
	}
	log.Secret(password)
	ptr, err := ReadPointers(p)
	if err != nil {
		return "", err
	}
	if ptr.Switch != nil {
		return "", ErrPending
	}
	c, key, err := Open(data, password)
	if err != nil {
		return "", err
	}
	defer clear(key)
	return applyOpened(p, data, c, key, ptr, log)
}

// applyOpened: общая часть Apply после проверки конфига (ptr без незавершённого переключения).
func applyOpened(p api.Paths, data []byte, c *api.Config, key []byte, ptr Pointers, log api.Logger) (string, error) {
	register(c, log)
	if err := os.MkdirAll(p.Config, 0o700); err != nil {
		return "", err
	}
	prune(p, ptr, log)
	next := 1
	if g := listGens(p); len(g) > 0 {
		next = g[len(g)-1].n + 1
	}
	name := "gen-" + strconv.Itoa(next)
	tmp := filepath.Join(p.Config, name+".new")
	_ = os.RemoveAll(tmp)
	if err := build(tmp, data, c, key); err != nil {
		_ = os.RemoveAll(tmp)
		return "", fmt.Errorf("config: build: %w", err)
	}
	if err := renameDurable(tmp, filepath.Join(p.Config, name)); err != nil {
		_ = os.RemoveAll(tmp)
		return "", fmt.Errorf("config: build: %w", err)
	}
	now := time.Now()
	sw := Switch{Op: "apply", From: ptr.Current, To: name, Started: now, Deadline: now.Add(api.ConfigSwitchSec * time.Second)}
	if err := writeSwitch(p, sw); err != nil {
		return "", err
	}
	if err := writeLine(p, "current", name); err != nil {
		_ = removeDurable(filepath.Join(p.Config, "switch.json"))
		return "", err
	}
	log.Info("config.apply", "gen", name, "from", ptr.Current)
	return name, nil
}

func build(dir string, data []byte, c *api.Config, key []byte) error {
	if err := mkPrivateDir(dir); err != nil {
		return err
	}
	priv := filepath.Join(dir, "private")
	if err := os.MkdirAll(filepath.Join(priv, "secrets", "entries"), 0o700); err != nil {
		return err
	}
	if !strings.HasSuffix(string(data), "\n") {
		data = append(append([]byte(nil), data...), '\n')
	}
	if err := writeFile(filepath.Join(dir, "active.json"), trimBOM(data), 0o600); err != nil {
		return err
	}
	s := c.Servers[0]
	idKey := strings.ReplaceAll(string(s.Key), "\r\n", "\n")
	if !strings.HasSuffix(idKey, "\n") {
		idKey += "\n"
	}
	if err := writeFile(filepath.Join(priv, "id_key"), []byte(idKey), 0o600); err != nil {
		return err
	}
	host := s.Host
	if s.Port != 22 {
		host = fmt.Sprintf("[%s]:%d", s.Host, s.Port)
	}
	if err := writeFile(filepath.Join(priv, "known_hosts"), []byte(host+" "+s.HostKey+"\n"), 0o600); err != nil {
		return err
	}
	if len(c.Paths.Channel) > 0 {
		if err := writeFile(filepath.Join(priv, "channel.json"), c.Paths.Channel, 0o600); err != nil {
			return err
		}
	}
	for n, v := range c.Paths.Secrets {
		if err := writeFile(filepath.Join(priv, "secrets", "entries", n+".json"), v, 0o600); err != nil {
			return err
		}
	}
	if err := writeKey(dir, key); err != nil {
		return err
	}
	meta, _ := json.Marshal(genMeta{Schema: SchemaVersion})
	if err := writeFile(filepath.Join(dir, "meta.json"), append(meta, '\n'), 0o600); err != nil {
		return err
	}
	return syncDir(dir)
}

// SaveKey stores the derived key of gen for autostart (DPAPI on Windows, file 600 elsewhere).
func SaveKey(p api.Paths, gen string, key []byte) error {
	if !genRe.MatchString(gen) {
		return errors.New("config: bad-gen")
	}
	return writeKey(GenDir(p, gen), key)
}

func readGenKey(dir string) ([]byte, error) { return readKey(dir) }

// loadGen opens generation gen with its saved key.
func loadGen(p api.Paths, gen string, log api.Logger) (*api.Config, error) {
	dir := GenDir(p, gen)
	data, err := os.ReadFile(filepath.Join(dir, "active.json"))
	if err != nil {
		return nil, fmt.Errorf("config: gen-missing: %s", gen)
	}
	if sc := GenSchema(p, gen); sc > SchemaVersion {
		return nil, fmt.Errorf("%w: %s записано более новой версией (схема %d, эта версия читает %d): выполните «remoteagents config revert» или вставьте конфиг заново", ErrNewerSchema, gen, sc, SchemaVersion)
	}
	key, err := readGenKey(dir)
	if err != nil {
		return nil, fmt.Errorf("config: key: cannot read key of %s", gen)
	}
	defer clear(key)
	c, err := OpenWithKey(data, key)
	if err != nil {
		return nil, err
	}
	register(c, log)
	return c, nil
}

// Load opens the current generation. Returns ErrNoConfig when there is none.
func Load(p api.Paths, log api.Logger) (*api.Config, string, error) {
	if log == nil {
		log = nopLog{}
	}
	ptr, err := ReadPointers(p)
	if err != nil {
		return nil, "", err
	}
	if ptr.Current == "" {
		return nil, "", ErrNoConfig
	}
	c, err := loadGen(p, ptr.Current, log)
	if err != nil {
		return nil, "", err
	}
	return c, ptr.Current, nil
}

// CheckCurrent is `config check --current`: the new version must read the saved generation (§7б).
func CheckCurrent(p api.Paths) error {
	_, _, err := Load(p, nil)
	return err
}

// Commit: channel is up with gen. lastgood = gen, mark good, drop switch.
func Commit(p api.Paths, gen string, sessionStarted time.Time) error {
	ptr, err := ReadPointers(p)
	if err != nil {
		return err
	}
	if ptr.Switch == nil {
		if gen != "" && gen == ptr.LastGood && gen == ptr.Current {
			return nil // already committed (idempotent)
		}
		return ErrStale
	}
	if gen != ptr.Switch.To || ptr.Current != gen || sessionStarted.Before(ptr.Switch.Started) {
		return ErrStale
	}
	_ = writeFile(filepath.Join(GenDir(p, gen), "good"), []byte("1\n"), 0o600)
	if err := writeLine(p, "lastgood", gen); err != nil {
		return err
	}
	return removeDurable(filepath.Join(p.Config, "switch.json"))
}

// Revert: with a switch go back to From; without one go to lastgood, or to the previous good generation.
func Revert(p api.Paths, log api.Logger) error {
	if log == nil {
		log = nopLog{}
	}
	ptr, err := ReadPointers(p)
	if err != nil {
		return err
	}
	if ptr.Switch != nil {
		return rollbackSwitch(p, ptr, log, "revert")
	}
	target := ""
	switch {
	case ptr.LastGood != "" && ptr.LastGood != ptr.Current && GenSchema(p, ptr.LastGood) <= SchemaVersion:
		target = ptr.LastGood
	default:
		cur := genNum(ptr.Current)
		for _, g := range listGens(p) {
			if (g.n < cur || ptr.Current == "") && GenSchema(p, g.name) <= SchemaVersion {
				if _, err := os.Stat(filepath.Join(GenDir(p, g.name), "good")); err == nil {
					target = g.name
				}
			}
		}
	}
	if target == "" {
		return ErrNoPrevious
	}
	if err := writeLine(p, "current", target); err != nil {
		return err
	}
	log.Info("config.revert", "from", ptr.Current, "to", target)
	return nil
}

func genNum(g string) int {
	if m := genRe.FindStringSubmatch(g); m != nil {
		n, _ := strconv.Atoi(m[1])
		return n
	}
	return 0
}

func rollbackSwitch(p api.Paths, ptr Pointers, log api.Logger, why string) error {
	if err := writeLine(p, "current", ptr.Switch.From); err != nil {
		return err
	}
	if err := removeDurable(filepath.Join(p.Config, "switch.json")); err != nil {
		return err
	}
	log.Warn("config."+why, "from", ptr.Switch.To, "to", ptr.Switch.From)
	return nil
}

// Expire (supervisor, at kernel start and on the switch deadline): deadline passed → current = From.
// Needs no running core.
func Expire(p api.Paths, now time.Time, log api.Logger) (bool, error) {
	if log == nil {
		log = nopLog{}
	}
	ptr, err := ReadPointers(p)
	if err != nil || ptr.Switch == nil || now.Before(ptr.Switch.Deadline) {
		return false, err
	}
	return true, rollbackSwitch(p, ptr, log, "expire")
}

type nopLog struct{}

func (nopLog) Info(string, ...any)                  {}
func (nopLog) Warn(string, ...any)                  {}
func (nopLog) Error(string, ...any)                 {}
func (n nopLog) With(string) api.Logger             { return n }
func (nopLog) Secret(string)                        {}
func (nopLog) Writer(string, string) io.WriteCloser { return discard{} }
func (nopLog) Drops() int64                         { return 0 }

type discard struct{}

func (discard) Write(b []byte) (int, error) { return len(b), nil }
func (discard) Close() error                { return nil }

// ExportCurrent отдаёт сохранённый конфиг текущего поколения как есть (с зашифрованными ключами, без пароля).
func ExportCurrent(p api.Paths) ([]byte, error) {
	ptr, err := ReadPointers(p)
	if err != nil {
		return nil, err
	}
	if ptr.Current == "" {
		return nil, ErrNoConfig
	}
	b, err := os.ReadFile(filepath.Join(GenDir(p, ptr.Current), "active.json"))
	if err != nil {
		return nil, fmt.Errorf("config: gen-missing: %s", ptr.Current)
	}
	return trimBOM(b), nil
}

// SetVPNMode меняет только vpn.mode в сохранённом конфиге и применяет его обычным путём Apply
// (новое поколение, switch.json, откат по сторожу). Пароль не нужен: берётся сохранённый ключ.
func SetVPNMode(p api.Paths, mode string, log api.Logger) (string, error) {
	if mode != "off" && mode != "auto" && mode != "only" {
		return "", errors.New("config: vpn-mode: режим должен быть off, auto или only")
	}
	if log == nil {
		log = nopLog{}
	}
	ptr, err := ReadPointers(p)
	if err != nil {
		return "", err
	}
	if ptr.Switch != nil {
		return "", ErrPending
	}
	if ptr.Current == "" {
		return "", ErrNoConfig
	}
	dir := GenDir(p, ptr.Current)
	data, err := ExportCurrent(p)
	if err != nil {
		return "", err
	}
	key, err := readGenKey(dir)
	if err != nil {
		return "", fmt.Errorf("config: key: cannot read key of %s", ptr.Current)
	}
	defer clear(key)
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var root map[string]any
	if err := dec.Decode(&root); err != nil {
		return "", fmt.Errorf("config: parse: %w", err)
	}
	vpn, _ := root["vpn"].(map[string]any)
	if vpn == nil {
		if _, has := root["vpn"]; has {
			return "", errors.New("config: vpn: раздел vpn не объект")
		}
		vpn = map[string]any{}
	}
	vpn["mode"] = mode
	root["vpn"] = vpn
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(root); err != nil {
		return "", err
	}
	nd := buf.Bytes()
	c, err := OpenWithKey(nd, key)
	if err != nil {
		return "", err
	}
	return applyOpened(p, nd, c, key, ptr, log)
}
