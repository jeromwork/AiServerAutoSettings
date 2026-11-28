package singbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func (s *box) Clash(ctx context.Context, method, path string, body, out any) error {
	u, err := url.Parse(path)
	if err != nil || !strings.HasPrefix(path, "/") || u.IsAbs() || u.Host != "" {
		return fmt.Errorf("singbox: clash-path: local relative path required")
	}
	var data []byte
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			return fmt.Errorf("singbox: clash-body: invalid JSON")
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, fmt.Sprintf("http://127.0.0.1:%d%s", s.clashPort(), path), bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("singbox: clash-request: invalid request")
	}
	req.Header.Set("Authorization", "Bearer "+s.rc.ClashSecret)
	req.Header.Set("Content-Type", "application/json")
	to := time.Second
	if _, ok := ctx.Deadline(); ok {
		to = 0 // срок задаёт вызывающий (например, проверка мостов группы ждёт до 20 с)
	}
	client := &http.Client{Timeout: to, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("singbox: clash-connect: request failed")
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("singbox: clash-status: HTTP %d", resp.StatusCode)
	}
	if out == nil {
		return nil
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out); err != nil {
		return fmt.Errorf("singbox: clash-decode: invalid response")
	}
	return nil
}

func (s *box) clashPort() int { s.vmu.Lock(); defer s.vmu.Unlock(); return s.vClash }
