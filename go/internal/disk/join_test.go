package disk

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const srvID = "MFZWI3D-BONSGYC-YLTMRWG-C43ENR5-QXGZDMM-FZWI3DP-BONSGYY-LTMRWAD"

const sampleCfg = `<configuration version="37"><folder id="default" path="~"></folder>
<device id="X" name="pc"><address>dynamic</address></device>
<gui enabled="true" tls="true"><address>127.0.0.1:8384</address><apikey>KEY</apikey></gui>
<options><relaysEnabled>true</relaysEnabled><urAccepted>3</urAccepted></options></configuration>`

func fakeGen(calls *int) func(context.Context, string, string) error {
	return func(_ context.Context, _, state string) error {
		*calls++
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "syncthing"},
			NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
		der, _ := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
		if err := os.WriteFile(filepath.Join(state, "cert.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(state, "config.xml"), []byte(sampleCfg), 0o600)
	}
}

func okReply() []byte { return []byte("{\"listen\":22001}\n" + srvID + "\n") }

func TestJoinHappy(t *testing.T) {
	home := t.TempDir()
	calls := 0
	var cmd string
	env := JoinEnv{Home: home, Generate: fakeGen(&calls), DeviceName: "Ноут",
		SSH: func(_ context.Context, c string, _ []byte) ([]byte, error) { cmd = c; return okReply(), nil }}
	info, err := Join(context.Background(), env)
	if err != nil || info.DeviceID != srvID || info.SyncPort != 22001 {
		t.Fatalf("%+v %v", info, err)
	}
	// команда несёт base64 с нашим ID и именем
	f := strings.Fields(cmd)
	raw, _ := base64.StdEncoding.DecodeString(f[3])
	var p map[string]string
	_ = json.Unmarshal(raw, &p)
	if !idRe.MatchString(p["deviceId"]) || p["deviceName"] != "Ноут" {
		t.Fatalf("%v", p)
	}
	b, _ := os.ReadFile(filepath.Join(home, "server.json"))
	if !strings.Contains(string(b), `"listen":22001`) {
		t.Fatal(string(b))
	}
	var j map[string]any
	b, _ = os.ReadFile(filepath.Join(home, "join.json"))
	_ = json.Unmarshal(b, &j)
	if j["stage"] != "folders" || j["serverId"] != srvID {
		t.Fatal(string(b))
	}
	// config.xml подготовлен
	cfg, _ := os.ReadFile(filepath.Join(home, "state", "config.xml"))
	s := string(cfg)
	for _, w := range []string{`tls="false"`, "<relaysEnabled>false</relaysEnabled>", "<urAccepted>-1</urAccepted>",
		"<apikey>KEY</apikey>", "tcp://127.0.0.1:", "<natEnabled>false</natEnabled>"} {
		if !strings.Contains(s, w) {
			t.Errorf("нет %s в %s", w, s)
		}
	}
	if strings.Contains(s, "<folder") || strings.Contains(s, "8384") {
		t.Error(s)
	}
	// повторный Join: без generate и без ssh
	env.SSH = func(context.Context, string, []byte) ([]byte, error) { t.Fatal("ssh"); return nil, nil }
	if _, err := Join(context.Background(), env); err != nil || calls != 1 {
		t.Fatalf("%v %d", err, calls)
	}
}

func TestJoinRetries(t *testing.T) {
	calls, n := 0, 0
	var pauses []time.Duration
	env := JoinEnv{Home: t.TempDir(), Generate: fakeGen(&calls),
		SSH: func(context.Context, string, []byte) ([]byte, error) {
			n++
			if n <= 4 {
				return nil, errors.New("down")
			}
			return okReply(), nil
		},
		Sleep: func(_ context.Context, d time.Duration) error { pauses = append(pauses, d); return nil }}
	if _, err := Join(context.Background(), env); err != nil {
		t.Fatal(err)
	}
	want := []time.Duration{60 * time.Second, 60 * time.Second, 60 * time.Second, 300 * time.Second}
	if len(pauses) != 4 {
		t.Fatal(pauses)
	}
	for i := range want {
		if pauses[i] != want[i] {
			t.Fatal(pauses)
		}
	}
}

func TestJoinCancel(t *testing.T) {
	calls := 0
	ctx, cancel := context.WithCancel(context.Background())
	env := JoinEnv{Home: t.TempDir(), Generate: fakeGen(&calls),
		SSH:   func(context.Context, string, []byte) ([]byte, error) { return nil, errors.New("x") },
		Sleep: func(ctx context.Context, _ time.Duration) error { cancel(); return ctx.Err() }}
	if _, err := Join(ctx, env); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestParseReplyBad(t *testing.T) {
	for _, s := range []string{"", "{\"listen\":0}\n" + srvID, "{\"listen\":22001}", "{\"listen\":22001.5}\n" + srvID} {
		if _, err := parseServerReply([]byte(s)); err == nil {
			t.Errorf("%q", s)
		}
	}
}

func TestIgnore(t *testing.T) {
	d := t.TempDir()
	if err := WriteIgnore(d); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(d, ".stignore"))
	r, _ := os.ReadFile(filepath.Join(d, ".stignore-remoteagents"))
	if string(b) != "#include .stignore-remoteagents\n" || !strings.Contains(string(r), "(?i).env*") ||
		!strings.Contains(string(r), "(?i)*.sql.zip") {
		t.Fatal(string(b), len(r))
	}
}
