package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hiddeco/sshsig"
	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
	"remoteagents/internal/update"
)

func init() {
	for _, name := range []string{"update", "p9"} {
		api.RegisterDev(api.DevCmd{
			Name: name,
			Help: "fake-release [dir] | serve --dir D --key K [--listen A] [--os O --arch A]",
			Run:  devUpdate,
		})
	}
}

func devUpdate(ctx context.Context, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev update fake-release [dir]")
		return 1
	}
	switch args[0] {
	case "fake-release":
		dir := ""
		if len(args) > 1 {
			dir = args[1]
		}
		if err := runFakeRelease(ctx, dir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	case "serve":
		if err := runServe(ctx, args[1:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown dev update command: %s\n", args[0])
		return 1
	}
}

func runFakeRelease(ctx context.Context, dir string) error {
	var workDir string
	var cleanupWorkDir bool
	if dir != "" {
		workDir = dir
		if err := os.MkdirAll(workDir, 0700); err != nil {
			return fmt.Errorf("update: dev: cannot create work dir: %w", err)
		}
	} else {
		tmp, err := os.MkdirTemp("", "ra3-dev-update-*")
		if err != nil {
			return fmt.Errorf("update: dev: cannot create temp dir: %w", err)
		}
		workDir = tmp
		cleanupWorkDir = true
	}
	if cleanupWorkDir {
		defer func() { _ = os.RemoveAll(workDir) }()
	}

	home := filepath.Join(workDir, "home")
	p := api.NewPaths(home)
	for _, d := range []string{p.Home, p.Tmp, p.Versions, p.Config} {
		if err := os.MkdirAll(d, 0700); err != nil {
			return fmt.Errorf("update: dev: cannot create directory %s: %w", d, err)
		}
	}

	_, privKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("update: dev: keygen failed: %w", err)
	}
	signer, err := ssh.NewSignerFromKey(privKey)
	if err != nil {
		return fmt.Errorf("update: dev: signer failed: %w", err)
	}
	sshPubKey := signer.PublicKey()
	authorizedKey := string(ssh.MarshalAuthorizedKey(sshPubKey))

	binName := "remoteagents-" + runtime.GOOS + "-" + runtime.GOARCH
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}

	// Build a native, disposable protocol fixture, including on Windows.
	fixtureDir, err := os.MkdirTemp(workDir, "fixture-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(fixtureDir) }()
	source := `package main
import ("encoding/json"; "os"; "runtime")
func main() {
 if len(os.Args)==3 && os.Args[1]=="version" && os.Args[2]=="--json" {
  _ = json.NewEncoder(os.Stdout).Encode(map[string]any{"version":"3.0.42","build":42,"os":runtime.GOOS,"arch":runtime.GOARCH})
  return
 }
 if len(os.Args)==6 && os.Args[1]=="config" && os.Args[2]=="check" && os.Args[3]=="--current" && os.Args[4]=="--home" { return }
 os.Exit(2)
}
`
	sourcePath := filepath.Join(fixtureDir, "candidate.go")
	if err := os.WriteFile(sourcePath, []byte(source), 0600); err != nil {
		return err
	}
	binaryPath := filepath.Join(fixtureDir, binName)
	buildCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(buildCtx, "go", "build", "-o", binaryPath, sourcePath)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("update: dev: build fixture: %w: %s", err, out)
	}
	candBytes, err := os.ReadFile(binaryPath)
	if err != nil {
		return err
	}
	candSha := sha256.Sum256(candBytes)
	candShaHex := hex.EncodeToString(candSha[:])

	versionBytes := []byte("3.0.42\n")
	verSha := sha256.Sum256(versionBytes)
	verShaHex := hex.EncodeToString(verSha[:])

	checksumsContent := fmt.Sprintf("%s  version.txt\n%s  %s\n", verShaHex, candShaHex, binName)

	sig, err := sshsig.Sign(strings.NewReader(checksumsContent), signer, sshsig.HashSHA256, "ra3-release")
	if err != nil {
		return fmt.Errorf("update: dev: sign failed: %w", err)
	}
	armoredSig := sshsig.Armor(sig)

	var corruptedSig atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/jeromwork/AiServerAutoSettings/releases/tags/v3-latest":
			rel := map[string]any{
				"tag_name": "v3-latest",
				"assets": []map[string]any{
					{"name": "checksums.txt", "browser_download_url": "http://" + r.Host + "/assets/checksums.txt", "size": len(checksumsContent)},
					{"name": "checksums.txt.sig", "browser_download_url": "http://" + r.Host + "/assets/checksums.txt.sig", "size": len(armoredSig)},
					{"name": "version.txt", "browser_download_url": "http://" + r.Host + "/assets/version.txt", "size": len(versionBytes)},
					{"name": binName, "browser_download_url": "http://" + r.Host + "/assets/" + binName, "size": len(candBytes)},
				},
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(rel)
		case "/assets/checksums.txt":
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte(checksumsContent))
		case "/assets/checksums.txt.sig":
			w.Header().Set("Content-Type", "text/plain")
			if corruptedSig.Load() {
				badSig := append([]byte(nil), armoredSig...)
				i := len(badSig) / 2
				if badSig[i] == 'A' {
					badSig[i] = 'B'
				} else {
					badSig[i] = 'A'
				}
				_, _ = w.Write(badSig)
			} else {
				_, _ = w.Write(armoredSig)
			}
		case "/assets/version.txt":
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write(versionBytes)
		case "/assets/" + binName:
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(candBytes)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	// 1. Successful verification and staging
	upd, err := update.New(p, nil, update.Options{
		Repo:    "jeromwork/AiServerAutoSettings",
		Channel: "v3-latest",
		Signers: []string{authorizedKey},
		BaseURL: server.URL,
	})
	if err != nil {
		return fmt.Errorf("update: dev: New failed: %w", err)
	}
	rel, err := upd.Check(ctx)
	if err != nil {
		return fmt.Errorf("update: dev: Check failed: %w", err)
	}
	if rel.Version != "3.0.42" {
		return fmt.Errorf("update: dev: unexpected version %s", rel.Version)
	}
	candidate, err := upd.Fetch(ctx, *rel)
	if err != nil {
		return fmt.Errorf("update: dev: Fetch failed: %w", err)
	}
	if err := upd.Stage(ctx, candidate, rel.Version); err != nil {
		return fmt.Errorf("update: dev: Stage failed: %w", err)
	}

	pendingFile := filepath.Join(p.Versions, "pending.json")
	pendingData, err := os.ReadFile(pendingFile)
	if err != nil {
		return fmt.Errorf("update: dev: pending.json missing: %w", err)
	}
	var pdoc struct {
		Dir string `json:"dir"`
	}
	if err := json.Unmarshal(pendingData, &pdoc); err != nil || pdoc.Dir != "3.0.42" {
		return fmt.Errorf("update: dev: invalid pending.json content: %s", string(pendingData))
	}
	slotDir := filepath.Join(p.Versions, "3.0.42")
	if fi, err := os.Stat(slotDir); err != nil || !fi.IsDir() {
		return fmt.Errorf("update: dev: slot directory missing")
	}
	fmt.Println("Install ok -> pending.json")

	// 2. Corrupted signature test
	home2 := filepath.Join(workDir, "home2")
	p2 := api.NewPaths(home2)
	for _, d := range []string{p2.Home, p2.Tmp, p2.Versions, p2.Config} {
		if err := os.MkdirAll(d, 0700); err != nil {
			return fmt.Errorf("update: dev: cannot create directory %s: %w", d, err)
		}
	}

	corruptedSig.Store(true)
	upd2, err := update.New(p2, nil, update.Options{
		Repo:    "jeromwork/AiServerAutoSettings",
		Channel: "v3-latest",
		Signers: []string{authorizedKey},
		BaseURL: server.URL,
	})
	if err != nil {
		return fmt.Errorf("update: dev: New(corrupted) failed: %w", err)
	}
	_, err = upd2.Check(ctx)
	if err == nil {
		return errors.New("update: dev: Check succeeded on corrupted signature; expected failure")
	}
	if !strings.Contains(err.Error(), "signature: invalid") {
		return fmt.Errorf("update: dev: expected 'signature: invalid', got %v", err)
	}

	slotDir2 := filepath.Join(p2.Versions, "3.0.42")
	if _, err := os.Stat(slotDir2); err == nil {
		return errors.New("update: dev: slot directory was created despite invalid signature")
	}
	pendingFile2 := filepath.Join(p2.Versions, "pending.json")
	if _, err := os.ReadFile(pendingFile2); err == nil {
		return errors.New("update: dev: pending.json was created despite invalid signature")
	}
	fmt.Println("signature: invalid, слота нет")

	return nil
}

// runServe поднимает тестовый «GitHub»: отдаёт из каталога --dir файлы remoteagents-<os>-<arch>[.exe] и version.txt,
// подписывая checksums.txt тестовым ключом --key (OpenSSH-секретный ключ без пароля). Файлы читаются при каждом
// запросе: подмена версии в каталоге не требует перезапуска. Проверка: docs/update-test.md.
func runServe(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	dir := fs.String("dir", "", "directory with the binary and version.txt")
	keyFile := fs.String("key", "", "test private key (OpenSSH, no passphrase)")
	listen := fs.String("listen", "127.0.0.1:0", "listen address")
	repo := fs.String("repo", "", "owner/repository (default: as built into the exe, see release-base docs)")
	channel := fs.String("channel", "v3-latest", "release tag")
	goos := fs.String("os", "windows", "target os")
	goarch := fs.String("arch", "amd64", "target arch")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" || *keyFile == "" || *repo == "" {
		return errors.New("usage: dev update serve --dir D --key K --repo owner/repo [--listen A] [--channel T] [--os O] [--arch A]")
	}
	raw, err := os.ReadFile(*keyFile)
	if err != nil {
		return err
	}
	signer, err := ssh.ParsePrivateKey(raw)
	if err != nil {
		return fmt.Errorf("serve: key: %w", err)
	}
	binName := "remoteagents-" + *goos + "-" + *goarch
	if *goos == "windows" {
		binName += ".exe"
	}
	snapshot := func() (bin, ver, sums, sig []byte, err error) {
		if bin, err = os.ReadFile(filepath.Join(*dir, binName)); err != nil {
			return
		}
		if ver, err = os.ReadFile(filepath.Join(*dir, "version.txt")); err != nil {
			return
		}
		bs, vs := sha256.Sum256(bin), sha256.Sum256(ver)
		sums = []byte(fmt.Sprintf("%s  version.txt\n%s  %s\n", hex.EncodeToString(vs[:]), hex.EncodeToString(bs[:]), binName))
		s, e := sshsig.Sign(strings.NewReader(string(sums)), signer, sshsig.HashSHA256, "ra3-release")
		if e != nil {
			err = e
			return
		}
		sig = sshsig.Armor(s)
		return
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	srv := &http.Server{ReadHeaderTimeout: 10 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bin, ver, sums, sig, err := snapshot()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		base := "http://" + r.Host
		switch r.URL.Path {
		case "/repos/" + *repo + "/releases/tags/" + *channel:
			asset := func(name string, b []byte) map[string]any {
				return map[string]any{"name": name, "browser_download_url": base + "/assets/" + name, "size": len(b)}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"tag_name": *channel, "assets": []map[string]any{
				asset("checksums.txt", sums), asset("checksums.txt.sig", sig), asset("version.txt", ver), asset(binName, bin)}})
		case "/assets/checksums.txt":
			_, _ = w.Write(sums)
		case "/assets/checksums.txt.sig":
			_, _ = w.Write(sig)
		case "/assets/version.txt":
			_, _ = w.Write(ver)
		case "/assets/" + binName:
			_, _ = w.Write(bin)
		default:
			http.NotFound(w, r)
		}
	})}
	go func() { <-ctx.Done(); _ = srv.Close() }()
	fmt.Println("release-base: http://" + ln.Addr().String())
	fmt.Println("public key (for SIGNERS_FILE): ra3 " + strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))))
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
