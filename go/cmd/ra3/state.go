package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var ignoredRegistries = map[string]bool{
	"exposed.json":  true,
	"reserved.json": true,
	"ports.lock":    true,
}

// State represents the saved PC connection state from ~/.local/state/ra-lab/<PC>.json.
type State struct {
	PC       string `json:"pc,omitempty"`
	Port     int    `json:"port"`
	Token    string `json:"token"`
	Version  string `json:"version,omitempty"`
	Rollback string `json:"rollback,omitempty"`
	PID      int    `json:"pid,omitempty"`
}

func defaultStateDir() string {
	if s := os.Getenv("RA_STATE_DIR"); s != "" {
		return s
	}
	if s := os.Getenv("RA_STATE"); s != "" {
		return s
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", ".local", "state", "ra-lab")
	}
	return filepath.Join(home, ".local", "state", "ra-lab")
}

func readState(stateDir, pcOrPath string) (*State, error) {
	var filePath string
	var pcName string

	if pcOrPath != "" {
		// If given an explicit path or filename ending with .json
		if strings.HasSuffix(pcOrPath, ".json") || filepath.IsAbs(pcOrPath) {
			filePath = pcOrPath
			pcName = strings.TrimSuffix(filepath.Base(pcOrPath), ".json")
		} else {
			// Check if pcOrPath exists directly as a file
			if fi, err := os.Stat(pcOrPath); err == nil && !fi.IsDir() {
				filePath = pcOrPath
				pcName = strings.TrimSuffix(filepath.Base(pcOrPath), ".json")
			} else {
				candidate := filepath.Join(stateDir, pcOrPath+".json")
				if _, err := os.Stat(candidate); err == nil {
					filePath = candidate
					pcName = pcOrPath
				} else {
					return nil, fmt.Errorf("ra3: ПК не подключался (нет %s)", candidate)
				}
			}
		}
	} else {
		// Find most recently modified *.json file in stateDir
		entries, err := os.ReadDir(stateDir)
		if err != nil {
			return nil, fmt.Errorf("ra3: ПК не подключался (нет состояния в %s: %w)", stateDir, err)
		}

		type candidate struct {
			path    string
			modTime time.Time
			name    string
		}
		var list []candidate

		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".tmp") || !strings.HasSuffix(name, ".json") {
				continue
			}
			if ignoredRegistries[name] {
				continue
			}
			fullPath := filepath.Join(stateDir, name)
			info, err := e.Info()
			if err != nil {
				continue
			}
			list = append(list, candidate{
				path:    fullPath,
				modTime: info.ModTime(),
				name:    strings.TrimSuffix(name, ".json"),
			})
		}

		if len(list) == 0 {
			return nil, fmt.Errorf("ra3: ПК не подключался (нет состояния в %s)", stateDir)
		}

		sort.Slice(list, func(i, j int) bool {
			return list[i].modTime.Before(list[j].modTime)
		})

		latest := list[len(list)-1]
		filePath = latest.path
		pcName = latest.name
	}

	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("ra3: не удалось прочитать %s: %w", filePath, err)
	}

	var st State
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, fmt.Errorf("ra3: повреждён файл состояния %s: %w", filePath, err)
	}

	if st.Port <= 0 || st.Port > 65535 || st.Token == "" {
		return nil, fmt.Errorf("ra3: неполное состояние в %s (port=%d, token=%t)", filePath, st.Port, st.Token != "")
	}

	st.PC = pcName
	if pcName == "" || pcName == "." || pcName == ".." || strings.ContainsAny(pcName, `/\\`) {
		return nil, fmt.Errorf("ra3: неверное имя ПК")
	}

	return &st, nil
}

func callAgent(ctx context.Context, st *State, method, path string, body io.Reader, headers map[string]string, timeout time.Duration) (int, []byte, error) {
	url := fmt.Sprintf("http://127.0.0.1:%d%s", st.Port, path)

	reqCtx := ctx
	var cancel context.CancelFunc
	if timeout > 0 {
		reqCtx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	req, err := http.NewRequestWithContext(reqCtx, method, url, body)
	if err != nil {
		return 0, nil, fmt.Errorf("ra3: ошибка создания запроса: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+st.Token)
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("ra3: канала нет (%w)", err)
	}
	defer resp.Body.Close()

	respData, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("ra3: ошибка чтения ответа: %w", err)
	}

	return resp.StatusCode, respData, nil
}

func callAgentJSON(ctx context.Context, st *State, method, path string, reqBody any, respOut any, timeout time.Duration) error {
	var bodyReader io.Reader
	headers := make(map[string]string)

	if reqBody != nil {
		b, err := json.Marshal(reqBody)
		if err != nil {
			return fmt.Errorf("ra3: ошибка маршалинга запроса: %w", err)
		}
		bodyReader = bytes.NewReader(b)
		headers["Content-Type"] = "application/json"
	}

	code, respData, err := callAgent(ctx, st, method, path, bodyReader, headers, timeout)
	if err != nil {
		return err
	}

	if code != http.StatusOK {
		var errObj struct {
			Error  string   `json:"error"`
			Errors []string `json:"errors"`
		}
		if json.Unmarshal(respData, &errObj) == nil {
			if len(errObj.Errors) > 0 {
				return fmt.Errorf("ra3: агент ответил %d:\n  %s", code, strings.Join(errObj.Errors, "\n  "))
			}
			if errObj.Error != "" {
				return fmt.Errorf("ra3: агент ответил %d: %s", code, errObj.Error)
			}
		}
		return fmt.Errorf("ra3: агент ответил %d: %s", code, strings.TrimSpace(string(respData)))
	}

	if respOut != nil {
		if err := json.Unmarshal(respData, respOut); err != nil {
			return fmt.Errorf("ra3: ошибка декодирования ответа: %w", err)
		}
	}

	return nil
}
