package config

import (
	"encoding/base64"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/secret"
)

const testPW = "pw-test"

// sealedConfig — минимальный валидный запечатанный конфиг; extra дополняет корень.
func sealedConfig(t *testing.T, extra map[string]any) []byte {
	t.Helper()
	salt := []byte("0123456789abcdef")
	key, err := secret.Derive(testPW, salt, 10)
	if err != nil {
		t.Fatal(err)
	}
	seal := func(s string) string {
		v, err := secret.Seal(key, []byte(s))
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	root := map[string]any{
		"format": "remoteagents-2",
		"name":   "pc-test",
		"server": map[string]any{"host": "h.example", "user": "u", "hostKey": "ssh-ed25519 AAAA", "key": seal("PRIVATE KEY\n")},
		"paths":  map[string]any{"channel": seal("{}")},
		"kdf":    map[string]any{"iterations": 10, "salt": base64.StdEncoding.EncodeToString(salt)},
		"check":  seal("remoteagents"),
	}
	for k, v := range extra {
		root[k] = v
	}
	b, err := json.Marshal(root)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func applyAndCommit(t *testing.T, p api.Paths, data []byte) {
	t.Helper()
	gen, err := Apply(p, data, testPW, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := Commit(p, gen, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
}

func decodeObj(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestSetVPNModeChangesOnlyMode(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	applyAndCommit(t, p, sealedConfig(t, map[string]any{
		"vpn":     map[string]any{"mode": "off", "bridges": []any{"a"}},
		"control": true,
	}))
	before, err := ExportCurrent(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SetVPNMode(p, "only", nil); err != nil {
		t.Fatal(err)
	}
	after, err := ExportCurrent(p)
	if err != nil {
		t.Fatal(err)
	}
	b, a := decodeObj(t, before), decodeObj(t, after)
	if a["vpn"].(map[string]any)["mode"] != "only" {
		t.Fatalf("mode не изменился: %v", a["vpn"])
	}
	b["vpn"].(map[string]any)["mode"] = "only"
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("изменилось не только vpn.mode:\n%v\n%v", b, a)
	}
	if _, err := Check(after, testPW); err != nil {
		t.Fatalf("конфиг после смены не проходит проверку: %v", err)
	}
}

func TestSetVPNModeCreatesSection(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	applyAndCommit(t, p, sealedConfig(t, nil))
	if _, err := SetVPNMode(p, "auto", nil); err != nil {
		t.Fatal(err)
	}
	after, _ := ExportCurrent(p)
	v, _ := decodeObj(t, after)["vpn"].(map[string]any)
	if v["mode"] != "auto" {
		t.Fatalf("vpn=%v", v)
	}
}

func TestSetVPNModeRejectsBadMode(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	applyAndCommit(t, p, sealedConfig(t, nil))
	if _, err := SetVPNMode(p, "bogus", nil); err == nil {
		t.Fatal("ожидалась ошибка")
	}
}
