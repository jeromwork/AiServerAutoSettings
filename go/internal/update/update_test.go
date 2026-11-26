package update

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hiddeco/sshsig"
	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
)

// Фейковый «GitHub» на httptest + настоящий исполняемый кандидат (маленькая Go-программа), который понимает
// `version --json` и `config check --current --home H` (отказывает, если в H лежит файл reject).
const candidateSrc = `package main
import ("encoding/json"; "os"; "path/filepath"; "runtime")
func main() {
 a := os.Args[1:]
 if len(a)==2 && a[0]=="version" && a[1]=="--json" {
  _ = json.NewEncoder(os.Stdout).Encode(map[string]any{"version":"3.0.42","os":runtime.GOOS,"arch":runtime.GOARCH,"schema":1})
  return
 }
 if len(a)==4 && a[0]=="config" && a[1]=="check" && a[2]=="--current" && a[3]=="--home" { os.Exit(2) }
 if len(a)==5 && a[0]=="config" && a[1]=="check" && a[2]=="--current" && a[3]=="--home" {
  if _, err := os.Stat(filepath.Join(a[4], "reject")); err == nil { os.Exit(1) }
  return
 }
 os.Exit(2)
}
`

var (
	buildOnce sync.Once
	candBytes []byte
	buildErr  error
)

func candidate(t *testing.T) []byte {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "ra3-cand-*")
		if err != nil {
			buildErr = err
			return
		}
		defer func() { _ = os.RemoveAll(dir) }()
		src := filepath.Join(dir, "main.go")
		if buildErr = os.WriteFile(src, []byte(candidateSrc), 0o600); buildErr != nil {
			return
		}
		goBin := filepath.Join(runtime.GOROOT(), "bin", "go")
		out := filepath.Join(dir, "cand")
		if runtime.GOOS == "windows" {
			out += ".exe"
		}
		cmd := exec.Command(goBin, "build", "-o", out, src)
		cmd.Dir = dir
		if b, err := cmd.CombinedOutput(); err != nil {
			buildErr = fmt.Errorf("%v: %s", err, b)
			return
		}
		candBytes, buildErr = os.ReadFile(out)
	})
	if buildErr != nil {
		t.Skipf("cannot build candidate: %v", buildErr)
	}
	return candBytes
}

type release struct {
	srv     *httptest.Server
	signers string
	mu      sync.Mutex
	badSig  bool
	badBin  bool
	bin     []byte
}

func newRelease(t *testing.T) *release {
	t.Helper()
	r := &release{bin: candidate(t)}
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	r.signers = string(ssh.MarshalAuthorizedKey(signer.PublicKey()))
	binName := "remoteagents-" + runtime.GOOS + "-" + runtime.GOARCH
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	ver := []byte("3.0.42\n")
	r.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		r.mu.Lock()
		defer r.mu.Unlock()
		bs, vs := sha256.Sum256(r.bin), sha256.Sum256(ver)
		sums := fmt.Sprintf("%s  version.txt\n%s  %s\n", hex.EncodeToString(vs[:]), hex.EncodeToString(bs[:]), binName)
		sg, _ := sshsig.Sign(strings.NewReader(sums), signer, sshsig.HashSHA256, "ra3-release")
		sig := sshsig.Armor(sg)
		if r.badSig {
			sig[len(sig)/2] ^= 1
		}
		base := "http://" + q.Host
		switch q.URL.Path {
		case "/repos/o/r/releases/tags/v3-latest":
			a := func(n string, size int) map[string]any {
				return map[string]any{"name": n, "browser_download_url": base + "/assets/" + n, "size": size}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"assets": []map[string]any{
				a("checksums.txt", len(sums)), a("checksums.txt.sig", len(sig)), a("version.txt", len(ver)), a(binName, len(r.bin))}})
		case "/assets/checksums.txt":
			_, _ = w.Write([]byte(sums))
		case "/assets/checksums.txt.sig":
			_, _ = w.Write(sig)
		case "/assets/version.txt":
			_, _ = w.Write(ver)
		case "/assets/" + binName:
			b := append([]byte(nil), r.bin...)
			if r.badBin {
				b[len(b)/2] ^= 1
			}
			_, _ = w.Write(b)
		default:
			http.NotFound(w, q)
		}
	}))
	t.Cleanup(r.srv.Close)
	return r
}

func (r *release) updater(t *testing.T, home string) (api.Updater, api.Paths) {
	t.Helper()
	p := api.NewPaths(home)
	for _, d := range []string{p.Tmp, p.Versions, p.Config} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	u, err := New(p, nil, Options{Repo: "o/r", Signers: []string{r.signers}, BaseURL: r.srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	return u, p
}

func fetchStage(t *testing.T, u api.Updater) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	rel, err := u.Check(ctx)
	if err != nil {
		return err
	}
	cand, err := u.Fetch(ctx, *rel)
	if err != nil {
		return err
	}
	return u.Stage(ctx, cand, rel.Version)
}

func noSlot(t *testing.T, p api.Paths) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(p.Versions, "3.0.42")); err == nil {
		t.Fatal("slot must not exist")
	}
	if _, err := os.Stat(filepath.Join(p.Versions, "pending.json")); err == nil {
		t.Fatal("pending.json must not exist")
	}
}

func TestStageAcceptsCandidateAndWritesPending(t *testing.T) {
	r := newRelease(t)
	u, p := r.updater(t, t.TempDir())
	if err := fetchStage(t, u); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(p.Versions, "pending.json")); err != nil {
		t.Fatal(err)
	}
}

// Причина «candidate rejected current config»: кандидат, не прочитавший текущий конфиг, не должен попасть в слот.
func TestStageRejectsCandidateThatRejectsConfig(t *testing.T) {
	r := newRelease(t)
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "reject"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	u, p := r.updater(t, home)
	err := fetchStage(t, u)
	if err == nil || !strings.Contains(err.Error(), "candidate rejected current config") {
		t.Fatalf("want config rejection, got %v", err)
	}
	noSlot(t, p)
}

func TestBadSignatureIsRefused(t *testing.T) {
	r := newRelease(t)
	r.badSig = true
	u, p := r.updater(t, t.TempDir())
	if err := fetchStage(t, u); err == nil {
		t.Fatal("bad signature accepted")
	}
	noSlot(t, p)
}

func TestTamperedBinaryIsRefused(t *testing.T) {
	r := newRelease(t)
	r.badBin = true
	u, p := r.updater(t, t.TempDir())
	err := fetchStage(t, u)
	if err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("want checksum mismatch, got %v", err)
	}
	noSlot(t, p)
}

// После отката слот версии остаётся на диске; повторное обновление на неё (тот же файл) допустимо и
// даёт только pending.json, а другой файл под тем же номером версии — отказ.
func TestStageReusesExistingIdenticalSlot(t *testing.T) {
	r := newRelease(t)
	u, p := r.updater(t, t.TempDir())
	if err := fetchStage(t, u); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(p.Versions, "pending.json")); err != nil { // как после отката
		t.Fatal(err)
	}
	if err := fetchStage(t, u); err != nil {
		t.Fatalf("second install of the same slot: %v", err)
	}
	if _, err := os.Stat(filepath.Join(p.Versions, "pending.json")); err != nil {
		t.Fatal("pending.json not written")
	}
	// Тот же номер, другой файл.
	slot := filepath.Join(p.Versions, "3.0.42", slotBinName(runtime.GOOS))
	if err := os.WriteFile(slot, []byte("other"), 0o700); err != nil {
		t.Fatal(err)
	}
	_ = os.Remove(filepath.Join(p.Versions, "pending.json"))
	if err := fetchStage(t, u); err == nil || !strings.Contains(err.Error(), "different binary") {
		t.Fatalf("want different-binary refusal, got %v", err)
	}
}
