package update

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/hiddeco/sshsig"

	"remoteagents/internal/api"
)

type asset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
	Size int64  `json:"size"`
}

type manifest struct {
	release api.Release
}

func (u *updater) metadata(ctx context.Context, address string) ([]byte, error) {
	resp, err := u.get(ctx, address)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.ContentLength > maxMetadata {
		return nil, fail("size", "metadata too large")
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxMetadata+1))
	if err != nil {
		return nil, fail("http", "metadata read failed: "+err.Error())
	}
	if len(b) > maxMetadata {
		return nil, fail("size", "metadata too large")
	}
	return b, nil
}

func (u *updater) signedManifest(ctx context.Context) (*manifest, error) {
	if len(u.keys) == 0 {
		return nil, fail("signature", "invalid: no signers configured")
	}
	endpoint := strings.TrimRight(u.o.BaseURL, "/") + "/repos/" + u.o.Repo + "/releases/tags/" + url.PathEscape(u.o.Channel)
	data, err := u.metadata(ctx, endpoint)
	if err != nil {
		return nil, err
	}
	var rel struct {
		Assets []asset `json:"assets"`
	}
	if err := json.Unmarshal(data, &rel); err != nil {
		return nil, fail("release", "invalid release JSON: "+err.Error())
	}
	assets := make(map[string]asset)
	for _, a := range rel.Assets {
		if _, ok := assets[a.Name]; ok {
			return nil, fail("release", "duplicate asset: "+a.Name)
		}
		assets[a.Name] = a
	}
	binName := "remoteagents-" + u.os + "-" + u.arch
	if u.os == "windows" {
		binName += ".exe"
	}
	for _, n := range []string{"checksums.txt", "checksums.txt.sig", "version.txt", binName} {
		a, ok := assets[n]
		if !ok || a.URL == "" {
			return nil, fail("release", "missing asset "+n)
		}
		if a.Size < 0 || a.Size > maxBinary {
			return nil, fail("size", "invalid asset size")
		}
	}
	checksums, err := u.metadata(ctx, assets["checksums.txt"].URL)
	if err != nil {
		return nil, err
	}
	signature, err := u.metadata(ctx, assets["checksums.txt.sig"].URL)
	if err != nil {
		return nil, err
	}
	sig, err := sshsig.Unarmor(signature)
	if err != nil {
		return nil, fail("signature", "invalid: unarmor failed: "+err.Error())
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
	sums := make(map[string]string)
	for _, line := range strings.Split(string(checksums), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) != 2 {
			return nil, fail("checksums", "invalid line in checksums.txt")
		}
		hash, err := hex.DecodeString(fields[0])
		if err != nil || len(hash) != sha256.Size {
			return nil, fail("checksums", "invalid sha256 in checksums.txt")
		}
		file := strings.TrimPrefix(fields[1], "*")
		file = filepath.Base(file)
		if _, ok := sums[file]; ok {
			return nil, fail("checksums", "duplicate filename in checksums.txt: "+file)
		}
		sums[file] = strings.ToLower(fields[0])
	}
	if _, ok := sums["version.txt"]; !ok {
		return nil, fail("checksums", "missing version.txt checksum")
	}
	if _, ok := sums[binName]; !ok {
		return nil, fail("checksums", "binary checksum missing")
	}
	versionData, err := u.metadata(ctx, assets["version.txt"].URL)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(versionData)
	if hex.EncodeToString(digest[:]) != sums["version.txt"] {
		return nil, fail("sha256", "version mismatch")
	}
	version := strings.TrimSpace(string(versionData))
	match := releasePattern.FindStringSubmatch(version)
	if !versionPattern.MatchString(version) || match == nil {
		return nil, fail("version", "invalid release version: "+version)
	}
	build, err := strconv.Atoi(match[1])
	if err != nil {
		return nil, fail("version", "invalid build: "+err.Error())
	}
	return &manifest{
		release: api.Release{
			Version: version,
			Build:   build,
			OS:      u.os,
			Arch:    u.arch,
			URL:     assets[binName].URL,
			SHA256:  sums[binName],
		},
	}, nil
}

func (u *updater) Check(ctx context.Context) (*api.Release, error) {
	m, err := u.signedManifest(ctx)
	if err != nil {
		return nil, err
	}
	return &m.release, nil
}

func (u *updater) Fetch(ctx context.Context, r api.Release) (string, error) {
	// Reauthenticate rather than trusting mutable caller-supplied Release fields.
	m, err := u.signedManifest(ctx)
	if err != nil {
		return "", err
	}
	if m.release != r {
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
	return u.ReceiveDev(ctx, resp.Body, r.SHA256, r.Version)
}
