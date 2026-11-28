package disk

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Client — REST-клиент локального Syncthing (127.0.0.1, X-API-Key). Ключ в ошибки не попадает.
type Client struct {
	BaseURL string // http://127.0.0.1:порт
	Key     string
	HTTP    *http.Client
}

var guiAddrRe = regexp.MustCompile(`^127\.0\.0\.1:([0-9]{1,5})$`)

// NewClient читает адрес и ключ из state/config.xml (state = Home/state).
func NewClient(state string) (*Client, error) {
	bad := errors.New("неверные локальные настройки Диска")
	root, err := readConfig(filepath.Join(state, "config.xml"))
	if err != nil {
		return nil, bad
	}
	gui := root.find("gui")
	if gui == nil {
		return nil, bad
	}
	addr, key := "", ""
	if n := gui.find("address"); n != nil {
		addr = strings.TrimSpace(n.Text)
	}
	if n := gui.find("apikey"); n != nil {
		key = strings.TrimSpace(n.Text)
	}
	if m := guiAddrRe.FindStringSubmatch(addr); m == nil || key == "" {
		return nil, bad
	}
	return NewClientURL("http://"+addr, key), nil
}

// NewClientURL — клиент для заданного адреса (тесты).
func NewClientURL(base, key string) *Client {
	return &Client{BaseURL: base, Key: key, HTTP: &http.Client{
		Timeout:       10 * time.Second,
		Transport:     &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 5 * time.Second}).DialContext},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

// Do — запрос к /rest/<path>; body (если не nil) шлётся JSON, ответ разбирается в out (если не nil).
func (c *Client) Do(ctx context.Context, method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+"/rest/"+strings.TrimLeft(path, "/"), rd)
	if err != nil {
		return errors.New("Диск не отвечает: неверный запрос")
	}
	req.Header.Set("X-API-Key", c.Key)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return errors.New("Диск не отвечает: не удалось выполнить локальный запрос")
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("Диск не отвечает: ошибка HTTP %d", resp.StatusCode)
	}
	if out != nil && len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			return errors.New("Диск вернул непонятный ответ")
		}
	}
	return nil
}

// FolderCfg — папка из config/folders (произвольный JSON-объект Syncthing).
type FolderCfg map[string]any

func (f FolderCfg) str(k string) string { s, _ := f[k].(string); return s }
func (f FolderCfg) ID() string          { return f.str("id") }
func (f FolderCfg) Label() string       { return f.str("label") }
func (f FolderCfg) Path() string        { return f.str("path") }
func (f FolderCfg) Paused() bool        { b, _ := f["paused"].(bool); return b }

// FolderStatus — db/status (ключевые поля).
type FolderStatus struct {
	State          string `json:"state"` // idle, scanning, syncing, sync-preparing, error, ...
	Error          string `json:"error"`
	GlobalBytes    int64  `json:"globalBytes"`
	LocalBytes     int64  `json:"localBytes"`
	NeedBytes      int64  `json:"needBytes"`
	NeedTotalItems int64  `json:"needTotalItems"`
}

// Pending — предложенная папка: настоящий ID и подпись.
type Pending struct {
	ID    string
	Label string
}

// MyID — ID этого устройства (system/status).
func (c *Client) MyID(ctx context.Context) (string, error) {
	var st struct {
		MyID string `json:"myID"`
	}
	if err := c.Do(ctx, "GET", "system/status", nil, &st); err != nil {
		return "", err
	}
	if st.MyID == "" {
		return "", errors.New("Диск не сообщил ID устройства")
	}
	return st.MyID, nil
}

func (c *Client) Folders(ctx context.Context) ([]FolderCfg, error) {
	var fs []FolderCfg
	return fs, c.Do(ctx, "GET", "config/folders", nil, &fs)
}

func (c *Client) FolderStatus(ctx context.Context, id string) (FolderStatus, error) {
	var st FolderStatus
	return st, c.Do(ctx, "GET", "db/status?folder="+url.QueryEscape(id), nil, &st)
}

func (c *Client) Pause(ctx context.Context, id string) error  { return c.setPaused(ctx, id, true) }
func (c *Client) Resume(ctx context.Context, id string) error { return c.setPaused(ctx, id, false) }

func (c *Client) setPaused(ctx context.Context, id string, v bool) error {
	return c.Do(ctx, "PATCH", "config/folders/"+url.PathEscape(id), map[string]any{"paused": v}, nil)
}

// Override — «этот ПК главный» (send-only); Revert — вернуть к состоянию сервера (receive-only).
func (c *Client) Override(ctx context.Context, id string) error {
	return c.Do(ctx, "POST", "db/override?folder="+url.QueryEscape(id), nil, nil)
}
func (c *Client) Revert(ctx context.Context, id string) error {
	return c.Do(ctx, "POST", "db/revert?folder="+url.QueryEscape(id), nil, nil)
}

// Scan — сканирование папки (sub — подпапка относительно корня, пусто — вся).
func (c *Client) Scan(ctx context.Context, id, sub string) error {
	q := "db/scan?folder=" + url.QueryEscape(id)
	if sub != "" {
		q += "&sub=" + url.QueryEscape(sub)
	}
	return c.Do(ctx, "POST", q, nil, nil)
}

// AddFolder создаёт папку; RemoveFolder убирает из настроек (файлы не трогает).
func (c *Client) AddFolder(ctx context.Context, f FolderCfg) error {
	return c.Do(ctx, "POST", "config/folders", f, nil)
}
func (c *Client) RemoveFolder(ctx context.Context, id string) error {
	return c.Do(ctx, "DELETE", "config/folders/"+url.PathEscape(id), nil, nil)
}

// PendingFolders — папки, предложенные устройством device.
func (c *Client) PendingFolders(ctx context.Context, device string) ([]Pending, error) {
	var m map[string]struct {
		OfferedBy map[string]struct {
			Label string `json:"label"`
		} `json:"offeredBy"`
	}
	if err := c.Do(ctx, "GET", "cluster/pending/folders?device="+url.QueryEscape(device), nil, &m); err != nil {
		return nil, err
	}
	var res []Pending
	for id, d := range m {
		if o, ok := d.OfferedBy[device]; ok {
			res = append(res, Pending{ID: id, Label: o.Label})
		}
	}
	return res, nil
}

// WaitReady ждёт, пока REST ответит (повторы по 250 мс, не больше tries раз).
func (c *Client) WaitReady(ctx context.Context, tries int) (string, error) {
	for i := 0; i < tries; i++ {
		if id, err := c.MyID(ctx); err == nil {
			return id, nil
		}
		if serr := sleepCtx(ctx, 250*time.Millisecond); serr != nil {
			return "", serr
		}
	}
	return "", errors.New("Диск не запустился")
}
