// Package update mirrors v2 update.py/updater.py: find a release, download it, check it, put it into a version slot.
// Only the caller (core) holds LockOp and restarts; this package never switches the running version.
package update

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/hiddeco/sshsig"
	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
)

const (
	maxBinary   = 100 << 20 // v2 MAX_SIZE
	maxMetadata = 1 << 20
	namespace   = "ra3-release" // sshsig namespace of checksums.txt.sig
	stagePrefix = ".stage-"     // cannot match VersionRe; never a version slot
)

var (
	versionRe = regexp.MustCompile(api.VersionRe)
	releaseRe = regexp.MustCompile(`^3\.0\.([0-9]+)$`)
)

type Options struct {
	Repo, Channel string
	Signers       []string // ssh public keys (authorized_keys lines); the signature of checksums.txt must match one of them
	Plat          api.Platform
	BaseURL       string
}

type updater struct {
	p        api.Paths
	log      api.Logger
	o        Options
	client   *http.Client
	keys     []ssh.PublicKey
	os, arch string
}

var _ api.Updater = (*updater)(nil)

func fail(code, reason string) error { return fmt.Errorf("update: %s: %s", code, reason) }

func New(p api.Paths, log api.Logger, o Options) (api.Updater, error) {
	if o.Channel == "" {
		o.Channel = "v3-latest"
	}
	if o.BaseURL == "" {
		o.BaseURL = "https://api.github.com"
	}
	if u, err := url.Parse(o.BaseURL); err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return nil, fail("url", "invalid release API base")
	}
	u := &updater{p: p, log: log, o: o, os: runtime.GOOS, arch: runtime.GOARCH}
	if o.Plat != nil {
		u.os, u.arch = o.Plat.OS(), o.Plat.Arch()
	}
	for _, entry := range o.Signers {
		for _, line := range strings.Split(entry, "\n") {
			if line = strings.TrimSpace(line); line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
			if err != nil {
				return nil, fail("signers", "invalid release public key: "+err.Error())
			}
			u.keys = append(u.keys, key)
		}
	}
	// No overall timeout: a binary may take long. 30 s applies to waiting for the server (v2 urlopen timeout).
	u.client = &http.Client{
		Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, ResponseHeaderTimeout: 30 * time.Second, TLSHandshakeTimeout: 30 * time.Second},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 || (via[0].URL.Scheme == "https" && req.URL.Scheme != "https") {
				return fail("http", "bad redirect")
			}
			return nil
		},
	}
	return u, nil
}

func (u *updater) exeName() string {
	if u.os == "windows" {
		return "remoteagents.exe"
	}
	return "remoteagents"
}

func (u *updater) get(ctx context.Context, address string) (*http.Response, error) {
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" || parsed.User != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") ||
		(strings.HasPrefix(u.o.BaseURL, "https:") && parsed.Scheme != "https") {
		return nil, fail("url", "invalid or insecure URL")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, fail("http", err.Error())
	}
	req.Header.Set("User-Agent", "remoteagents-v3")
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := u.client.Do(req)
	if err != nil {
		return nil, fail("http", "request failed: "+err.Error())
	}
	if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		return nil, fail("http", fmt.Sprintf("status %d", resp.StatusCode))
	}
	return resp, nil
}

func (u *updater) small(ctx context.Context, address string) ([]byte, error) {
	resp, err := u.get(ctx, address)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxMetadata+1))
	if err != nil {
		return nil, fail("http", "read failed: "+err.Error())
	}
	if len(b) > maxMetadata {
		return nil, fail("size", "metadata too large")
	}
	return b, nil
}

// manifest is v2 check(): the release by tag, but trusted only after the signature of checksums.txt is verified.
func (u *updater) manifest(ctx context.Context) (*api.Release, error) {
	if len(u.keys) == 0 {
		return nil, fail("signature", "no signers configured")
	}
	data, err := u.small(ctx, strings.TrimRight(u.o.BaseURL, "/")+"/repos/"+u.o.Repo+"/releases/tags/"+url.PathEscape(u.o.Channel))
	if err != nil {
		return nil, err
	}
	var rel struct {
		Assets []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
			Size int64  `json:"size"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(data, &rel); err != nil {
		return nil, fail("release", "invalid release JSON: "+err.Error())
	}
	binName := "remoteagents-" + u.os + "-" + u.arch
	if u.os == "windows" {
		binName += ".exe"
	}
	urls := map[string]string{}
	for _, a := range rel.Assets {
		if _, dup := urls[a.Name]; dup {
			return nil, fail("release", "duplicate asset: "+a.Name)
		}
		if a.Size < 0 || a.Size > maxBinary {
			return nil, fail("size", "invalid asset size: "+a.Name)
		}
		urls[a.Name] = a.URL
	}
	for _, n := range []string{"checksums.txt", "checksums.txt.sig", "version.txt", binName} {
		if urls[n] == "" {
			return nil, fail("release", "missing asset "+n)
		}
	}
	checksums, err := u.small(ctx, urls["checksums.txt"])
	if err != nil {
		return nil, err
	}
	armored, err := u.small(ctx, urls["checksums.txt.sig"])
	if err != nil {
		return nil, err
	}
	sig, err := sshsig.Unarmor(armored)
	if err != nil {
		return nil, fail("signature", "invalid: "+err.Error())
	}
	verified := false
	for _, key := range u.keys {
		if sshsig.Verify(bytes.NewReader(checksums), sig, key, sig.HashAlgorithm, namespace) == nil {
			verified = true
			break
		}
	}
	if !verified {
		return nil, fail("signature", "invalid")
	}
	sums := map[string]string{}
	for _, line := range strings.Split(string(checksums), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if raw, err := hex.DecodeString(f[0]); len(f) != 2 || err != nil || len(raw) != sha256.Size {
			return nil, fail("checksums", "invalid line in checksums.txt")
		}
		name := filepath.Base(strings.TrimPrefix(f[1], "*"))
		if _, dup := sums[name]; dup {
			return nil, fail("checksums", "duplicate file in checksums.txt: "+name)
		}
		sums[name] = strings.ToLower(f[0])
	}
	if sums["version.txt"] == "" || sums[binName] == "" {
		return nil, fail("checksums", "version.txt or binary missing in checksums.txt")
	}
	vdata, err := u.small(ctx, urls["version.txt"])
	if err != nil {
		return nil, err
	}
	if d := sha256.Sum256(vdata); hex.EncodeToString(d[:]) != sums["version.txt"] {
		return nil, fail("sha256", "version.txt mismatch")
	}
	version := strings.TrimSpace(string(vdata))
	m := releaseRe.FindStringSubmatch(version)
	if m == nil || !versionRe.MatchString(version) {
		return nil, fail("version", "invalid release version: "+version)
	}
	build, _ := strconv.Atoi(m[1])
	return &api.Release{Version: version, Build: build, OS: u.os, Arch: u.arch, URL: urls[binName], SHA256: sums[binName]}, nil
}

func (u *updater) Check(ctx context.Context) (*api.Release, error) { return u.manifest(ctx) }

func (u *updater) Fetch(ctx context.Context, r api.Release) (string, error) {
	// The caller's Release is not trusted: take the signed one again and require it to be identical.
	m, err := u.manifest(ctx)
	if err != nil {
		return "", err
	}
	if *m != r {
		return "", fail("release", "release changed; check again")
	}
	resp, err := u.get(ctx, r.URL)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.ContentLength > maxBinary {
		return "", fail("size", "binary exceeds 100 MiB")
	}
	if r.SHA256 == "" { // sha is mandatory for a release
		return "", fail("sha256", "no sha256")
	}
	return u.ReceiveDev(ctx, resp.Body, r.SHA256, r.Version)
}

// ReceiveDev is v2 Updater.install front half: read at most 100 MiB into Tmp and compare sha256 (v2: the check is skipped when sha is empty).
func (u *updater) ReceiveDev(ctx context.Context, body io.Reader, sha, version string) (string, error) {
	if !versionRe.MatchString(version) {
		return "", fail("version", "invalid version")
	}
	sha = strings.ToLower(strings.TrimSpace(sha))
	if err := os.MkdirAll(u.p.Tmp, 0o700); err != nil {
		return "", fail("tmp", err.Error())
	}
	f, err := os.CreateTemp(u.p.Tmp, "candidate-*")
	if err != nil {
		return "", fail("tmp", err.Error())
	}
	path, ok := f.Name(), false
	defer func() {
		if !ok {
			_ = os.Remove(path)
		}
	}()
	h := sha256.New()
	if closer, isCloser := body.(io.Closer); isCloser { // an HTTP body unblocks on Close when ctx ends
		stop := context.AfterFunc(ctx, func() { _ = closer.Close() })
		defer stop()
	}
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(body, maxBinary+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	switch {
	case err != nil:
		return "", fail("io", err.Error())
	case n > maxBinary:
		return "", fail("size", "binary exceeds 100 MiB")
	case n == 0:
		return "", fail("size", "empty file")
	}
	if got := hex.EncodeToString(h.Sum(nil)); sha != "" && sha != got {
		return "", fail("sha256", "mismatch (got "+got[:12]+")")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return "", fail("chmod", err.Error())
	}
	ok = true
	return path, nil
}

// Stage is v2 install back half: check the candidate (v2: compile every file; here: it must start and answer `version --json`),
// put it into Versions/<version>/ and write Versions/pending.json = {"dir": "<version>"}. The core then exits with code 3.
func (u *updater) Stage(ctx context.Context, candidate, version string) error {
	if !versionRe.MatchString(version) {
		return fail("version", "invalid version")
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second) // one-action timeout
	out, err := exec.CommandContext(cctx, candidate, "version", "--json").Output()
	cancel()
	var info map[string]string
	if err != nil || json.Unmarshal(out, &info) != nil || info["version"] == "" {
		_ = os.Remove(candidate)
		return fail("candidate", "does not start or does not report its version")
	}
	final := filepath.Join(u.p.Versions, version)
	if _, err := os.Stat(final); err == nil {
		old, err := fileHash(filepath.Join(final, u.exeName()))
		if err != nil {
			return fail("slot", err.Error())
		}
		got, err := fileHash(candidate)
		if err != nil {
			return fail("candidate", err.Error())
		}
		if old != got {
			return fail("version", "slot already exists with different binary")
		}
		_ = os.Remove(candidate)
	} else if !os.IsNotExist(err) {
		return fail("write", err.Error())
	} else {
		if err := os.MkdirAll(u.p.Versions, 0o700); err != nil {
			return fail("write", err.Error())
		}
		tmp, err := os.MkdirTemp(u.p.Versions, stagePrefix)
		if err != nil {
			return fail("write", err.Error())
		}
		defer os.RemoveAll(tmp)
		if err := os.Rename(candidate, filepath.Join(tmp, u.exeName())); err != nil {
			return fail("write", err.Error())
		}
		if err := os.Rename(tmp, final); err != nil {
			return fail("write", err.Error())
		}
	}
	b, _ := json.Marshal(map[string]string{"dir": version})
	pending := filepath.Join(u.p.Versions, "pending.json")
	if err := os.WriteFile(pending+".tmp", b, 0o600); err != nil {
		return fail("write", err.Error())
	}
	if err := os.Rename(pending+".tmp", pending); err != nil {
		return fail("write", err.Error())
	}
	u.prune(version)
	if u.log != nil {
		u.log.Info("update.staged", "version", version)
	}
	return nil
}

func fileHash(path string) ([sha256.Size]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	defer f.Close()
	h := sha256.New()
	_, err = io.Copy(h, f)
	return [sha256.Size]byte(h.Sum(nil)), err
}

// prune keeps the new slot and everything named in state.json, removes abandoned
// staging directories, then keeps at most 5 slots (newest first).
func (u *updater) prune(keep string) {
	protect := map[string]bool{keep: true}
	if b, err := os.ReadFile(filepath.Join(u.p.Versions, "state.json")); err == nil {
		var st map[string]any
		if json.Unmarshal(b, &st) == nil {
			for _, v := range st {
				if s, ok := v.(string); ok {
					protect[s] = true
				}
			}
		}
	}
	ents, err := os.ReadDir(u.p.Versions)
	if err != nil {
		return
	}
	type slot struct {
		name string
		mod  time.Time
	}
	var ours []slot
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		switch n := e.Name(); {
		case protect[n]:
			continue
		case strings.HasPrefix(n, stagePrefix):
			_ = os.RemoveAll(filepath.Join(u.p.Versions, n))
		case versionRe.MatchString(n):
			if fi, err := e.Info(); err == nil {
				ours = append(ours, slot{n, fi.ModTime()})
			}
		}
	}
	sort.Slice(ours, func(i, j int) bool { return ours[i].mod.After(ours[j].mod) })
	for i := max(0, api.MaxSlots-len(protect)); i < len(ours); i++ {
		_ = os.RemoveAll(filepath.Join(u.p.Versions, ours[i].name))
	}
}
