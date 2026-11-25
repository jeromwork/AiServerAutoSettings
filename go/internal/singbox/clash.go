package singbox

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const delayURL = "https://www.gstatic.com/generate_204"

func (s *controller) Clash(ctx context.Context, method, path string, body, out any) error {
	s.mu.Lock()
	port, secret := s.clashPort, s.secret
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	response, err := clashRequest(ctx, port, secret, method, path, body)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 204 {
		return fmt.Errorf("clash: HTTP %d", response.StatusCode)
	}
	if out != nil && response.StatusCode != 204 {
		return json.NewDecoder(response.Body).Decode(out)
	}
	_, err = io.Copy(io.Discard, response.Body)
	return err
}
func clashRequest(ctx context.Context, port int, secret, method, path string, body any) (*http.Response, error) {
	var b []byte
	var err error
	if body != nil {
		b, err = json.Marshal(body)
		if err != nil {
			return nil, err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, fmt.Sprintf("http://127.0.0.1:%d%s", port, path), bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")
	return clashClient.Do(req)
}
func (s *controller) Delay(ctx context.Context, path string, timeoutMS int) (*int, error) {
	var out struct {
		Delay *int `json:"delay"`
	}
	err := s.Clash(ctx, "GET", "/proxies/"+url.PathEscape(path)+"/delay?url="+url.QueryEscape(delayURL)+fmt.Sprintf("&timeout=%d", timeoutMS), nil, &out)
	return out.Delay, err
}
func (s *controller) Select(ctx context.Context, selector, path string) error {
	return s.Clash(ctx, "PUT", "/proxies/"+url.PathEscape(selector), object{"name": path}, nil)
}

// startTraffic is called under mu after the log announces readiness. No polling.
func (s *controller) startTraffic() {
	if s.trafficCancel != nil {
		s.trafficCancel()
	}
	ctx, cancel := context.WithCancel(s.ctx)
	s.trafficCancel = cancel
	port, secret := s.clashPort, s.secret
	go func() {
		response, err := clashRequest(ctx, port, secret, "GET", "/traffic", nil)
		if err == nil {
			defer response.Body.Close()
			if response.StatusCode == 200 {
				scan := bufio.NewScanner(response.Body)
				for scan.Scan() {
					var d struct{ Up, Down int64 }
					if json.Unmarshal(scan.Bytes(), &d) != nil {
						break
					}
					s.mu.Lock()
					if s.clashPort != port {
						s.mu.Unlock()
						return
					}
					active := d.Up+d.Down > 2048
					was := s.traffic["active"]
					s.traffic = object{"up_bps": d.Up, "down_bps": d.Down, "active": active}
					if was != active {
						s.info("traffic", "data", s.traffic)
					}
					s.mu.Unlock()
				}
			}
		}
		s.mu.Lock()
		current := s.clashPort == port && s.up && !s.stopping
		if s.clashPort == port {
			s.traffic = object{"up_bps": int64(0), "down_bps": int64(0), "active": false}
		}
		s.mu.Unlock()
		if current && ctx.Err() == nil {
			s.bus.Publish("singbox.stream.closed", object{"stream": "traffic"})
		}
	}()
}
