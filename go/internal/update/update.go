// Package update downloads authenticated candidates; the caller owns LockOp and restart policy.
package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
)

const maxBinary = 100 << 20
const maxMetadata = 1 << 20
const namespace = "ra3-release"

var versionPattern = regexp.MustCompile(api.VersionRe)
var releasePattern = regexp.MustCompile(`^3\.0\.([0-9]+)$`)

type Options struct {
	Repo, Channel string
	Signers       []string
	Plat          api.Platform
	Interval      time.Duration
	BaseURL       string
}

type updater struct {
	stageMu  sync.Mutex
	p        api.Paths
	log      api.Logger
	o        Options
	client   *http.Client
	keys     []ssh.PublicKey
	os, arch string
}

func fail(code, reason string) error { return fmt.Errorf("update: %s: %s", code, reason) }

var _ api.Updater = (*updater)(nil)

func parsePublicKey(line string) (ssh.PublicKey, error) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return nil, nil
	}
	fields := strings.Fields(line)
	keyIdx := -1
	for i, f := range fields {
		if strings.HasPrefix(f, "ssh-") || strings.HasPrefix(f, "ecdsa-") {
			keyIdx = i
			break
		}
	}
	var keyLine string
	if keyIdx >= 0 {
		keyLine = strings.Join(fields[keyIdx:], " ")
	} else {
		keyLine = line
	}
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(keyLine))
	if err != nil {
		return nil, err
	}
	return pub, nil
}

func New(p api.Paths, log api.Logger, o Options) (api.Updater, error) {
	if p.Tmp == "" || p.Versions == "" || p.Home == "" {
		return nil, fail("paths", "home, tmp and versions are required")
	}
	if o.Channel == "" {
		o.Channel = "v3-latest"
	}
	if o.BaseURL == "" {
		o.BaseURL = "https://api.github.com"
	}
	base, err := url.Parse(o.BaseURL)
	if err != nil || base.Host == "" || (base.Scheme != "https" && base.Scheme != "http") || base.RawQuery != "" || base.Fragment != "" || base.User != nil {
		return nil, fail("url", "invalid release API base")
	}
	parts := strings.Split(o.Repo, "/")
	if len(parts) != 2 || !versionPattern.MatchString(parts[0]) || !versionPattern.MatchString(parts[1]) {
		return nil, fail("repo", "expected owner/repository")
	}
	u := &updater{p: p, log: log, o: o, os: runtime.GOOS, arch: runtime.GOARCH}
	if o.Plat != nil {
		u.os, u.arch = o.Plat.OS(), o.Plat.Arch()
	}
	for _, entry := range o.Signers {
		for _, line := range strings.Split(entry, "\n") {
			pub, err := parsePublicKey(line)
			if err != nil {
				return nil, fail("signers", "invalid release public key: "+err.Error())
			}
			if pub != nil {
				u.keys = append(u.keys, pub)
			}
		}
	}
	u.client = &http.Client{
		Timeout: 30 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return fail("http", "too many redirects")
			}
			if via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
				return fail("http", "insecure redirect")
			}
			return nil
		},
	}
	return u, nil
}

func (u *updater) get(ctx context.Context, address string) (*http.Response, error) {
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" || parsed.User != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return nil, fail("url", "invalid asset URL")
	}
	if strings.HasPrefix(u.o.BaseURL, "https:") && parsed.Scheme != "https" {
		return nil, fail("url", "HTTPS required")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, fail("http", "cannot create request")
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

func (u *updater) ReceiveDev(ctx context.Context, body io.Reader, sha256Hex, version string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", fail("cancelled", err.Error())
	}
	// HTTP bodies and pipes can unblock Read on Close. An arbitrary io.Reader
	// has no cancellation operation; it must itself honor the caller's context.
	if closer, ok := body.(io.ReadCloser); ok {
		stop := context.AfterFunc(ctx, func() { _ = closer.Close() })
		defer stop()
	}
	if !versionPattern.MatchString(version) {
		return "", fail("version", "invalid version: "+version)
	}
	expectedSha := strings.ToLower(strings.TrimSpace(sha256Hex))
	if len(expectedSha) != 64 {
		return "", fail("sha256", "invalid sha256 length")
	}
	if _, err := hex.DecodeString(expectedSha); err != nil {
		return "", fail("sha256", "invalid sha256 hex: "+err.Error())
	}
	if err := os.MkdirAll(u.p.Tmp, 0700); err != nil {
		return "", fail("tmp", "cannot create tmp directory: "+err.Error())
	}
	suffix := ".tmp"
	if u.os == "windows" {
		suffix = ".exe"
	}
	tmpFile, err := os.CreateTemp(u.p.Tmp, "candidate-*"+suffix)
	if err != nil {
		return "", fail("tmp", "cannot create temporary candidate file: "+err.Error())
	}
	candPath := tmpFile.Name()

	var success bool
	defer func() {
		if !success {
			_ = tmpFile.Close()
			_ = os.Remove(candPath)
		}
	}()

	hasher := sha256.New()
	writer := io.MultiWriter(tmpFile, hasher)
	written, err := io.Copy(writer, io.LimitReader(&contextReader{ctx: ctx, r: body}, maxBinary+1))
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	if closeErr := tmpFile.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return "", fail("io", "error writing candidate: "+err.Error())
	}
	if written > maxBinary {
		return "", fail("size", "binary exceeds 100 MiB")
	}
	if written == 0 {
		return "", fail("size", "candidate binary is empty")
	}
	actualSha := hex.EncodeToString(hasher.Sum(nil))
	if actualSha != expectedSha {
		return "", fail("sha256", fmt.Sprintf("checksum mismatch: got %s, want %s", actualSha, expectedSha))
	}
	if err := os.Chmod(candPath, 0700); err != nil { // #nosec G302 -- authenticated candidate requires owner execute permission.
		return "", fail("chmod", err.Error())
	}
	success = true
	return candPath, nil
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(p)
}
