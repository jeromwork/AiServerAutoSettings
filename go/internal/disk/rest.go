package disk

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"time"
)

func jsonBytes(v any) ([]byte, error) { return json.Marshal(v) }
func readBytes(b []byte, v any) error { return json.Unmarshal(b, v) }

type rest struct {
	base, key string
	client    *http.Client
}

func (d *Disk) localAPI() (*rest, error) {
	root, e := loadXML(filepath.Join(d.home, "state"))
	if e != nil {
		return nil, errors.New("Неверные локальные настройки Диска.")
	}
	gui := root.child("gui")
	if gui == nil {
		return nil, errSettings
	}
	address, key := gui.text("address"), gui.text("apikey")
	match := regexp.MustCompile(`^127\.0\.0\.1:([0-9]{1,5})$`).FindStringSubmatch(address)
	if match == nil || key == "" {
		return nil, errSettings
	}
	port, _ := strconv.Atoi(match[1])
	if port < 1 || port > 65535 {
		return nil, errSettings
	}
	if d.o.Log != nil {
		d.o.Log.Secret(key)
	}
	return &rest{base: "http://" + address, key: key, client: &http.Client{Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (r *rest) call(ctx context.Context, method, path string, body, dst any, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var input io.Reader
	if body != nil {
		b, e := json.Marshal(body)
		if e != nil {
			return e
		}
		input = bytes.NewReader(b)
	}
	req, e := http.NewRequestWithContext(ctx, method, r.base+"/rest/"+path, input)
	if e != nil {
		return errors.New("Неверный локальный запрос Диска.")
	}
	req.Header.Set("X-API-Key", r.key)
	req.Header.Set("Content-Type", "application/json")
	response, e := r.client.Do(req)
	if e != nil {
		return errors.New("Диск не отвечает: не удалось выполнить локальный запрос.")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("Диск не отвечает: ошибка HTTP %d.", response.StatusCode)
	}
	b, e := io.ReadAll(response.Body)
	if e != nil {
		return errors.New("Диск не отвечает: не удалось прочитать локальный ответ.")
	}
	if dst != nil && len(bytes.TrimSpace(b)) > 0 {
		if json.Unmarshal(b, dst) != nil {
			return errors.New("Диск не отвечает: неверный локальный ответ.")
		}
	}
	return nil
}
func (r *rest) get(ctx context.Context, path string, dst any) error {
	return r.call(ctx, "GET", path, nil, dst, 10*time.Second)
}
func (r *rest) put(ctx context.Context, method, path string, v any) error {
	return r.call(ctx, method, path, v, nil, 10*time.Second)
}

type event struct {
	ID   int64  `json:"id"`
	Type string `json:"type"`
}

func (r *rest) events(ctx context.Context, since int64) ([]event, error) {
	var events []event
	e := r.call(ctx, "GET", "events?since="+strconv.FormatInt(since, 10)+"&timeout=60", nil, &events, 70*time.Second)
	return events, e
}
func (r *rest) setServer(ctx context.Context, id string, port int) error {
	var devices []map[string]any
	if e := r.get(ctx, "config/devices", &devices); e != nil {
		return e
	}
	address := "tcp://127.0.0.1:" + strconv.Itoa(port)
	route := "config/devices/" + url.PathEscape(id)
	for _, device := range devices {
		if device["deviceID"] == id {
			patch := map[string]any{}
			addresses, _ := device["addresses"].([]any)
			if len(addresses) != 1 || addresses[0] != address {
				patch["addresses"] = []string{address}
			}
			if device["autoAcceptFolders"] == true {
				patch["autoAcceptFolders"] = false
			}
			if len(patch) > 0 {
				return r.put(ctx, "PATCH", route, patch)
			}
			return nil
		}
	}
	var device map[string]any
	if e := r.get(ctx, "config/defaults/device", &device); e != nil {
		return e
	}
	device["deviceID"], device["name"], device["addresses"], device["autoAcceptFolders"] = id, "RemoteDisk Server", []string{address}, false
	return r.put(ctx, "PUT", route, device)
}
