package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

func cmdLog(ctx context.Context, stateDir, pc string, follow bool, count int, interval time.Duration) error {
	st, err := readState(stateDir, pc)
	if err != nil {
		return err
	}

	if count <= 0 {
		count = 200
	}
	if interval <= 0 {
		interval = time.Second
	}

	records, err := fetchLogs(ctx, st, count)
	if err != nil {
		return err
	}

	seen := make(map[string]bool)
	for _, rec := range records {
		line := formatLogRecord(rec)
		seen[line] = true
		fmt.Println(line)
	}

	if !follow {
		return nil
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			recs, err := fetchLogs(ctx, st, count)
			if err != nil {
				// Don't crash follow on transient network error, just retry
				continue
			}
			for _, rec := range recs {
				line := formatLogRecord(rec)
				if !seen[line] {
					seen[line] = true
					fmt.Println(line)
				}
			}
			// Keep seen map bounded to prevent infinite memory growth
			if len(seen) > 5000 {
				newSeen := make(map[string]bool, 1000)
				for _, rec := range recs {
					newSeen[formatLogRecord(rec)] = true
				}
				seen = newSeen
			}
		}
	}
}

func fetchLogs(ctx context.Context, st *State, n int) ([]any, error) {
	path := fmt.Sprintf("/log?n=%d", n)
	code, respData, err := callAgent(ctx, st, "GET", path, nil, nil, 10*time.Second)
	if err != nil {
		return nil, err
	}

	if code != http.StatusOK {
		return nil, fmt.Errorf("ra3: агент ответил %d: %s", code, strings.TrimSpace(string(respData)))
	}

	var resp struct {
		Records []any `json:"records"`
	}
	if err := json.Unmarshal(respData, &resp); err != nil {
		// Could be a raw array of lines
		var rawArr []any
		if err2 := json.Unmarshal(respData, &rawArr); err2 == nil {
			return rawArr, nil
		}
		return nil, fmt.Errorf("ra3: ошибка декодирования журнала: %w", err)
	}

	return resp.Records, nil
}

func formatLogRecord(rec any) string {
	switch r := rec.(type) {
	case string:
		var m map[string]any
		if err := json.Unmarshal([]byte(r), &m); err == nil {
			return formatRecordMap(m)
		}
		return r
	case map[string]any:
		return formatRecordMap(r)
	default:
		b, err := json.Marshal(r)
		if err != nil {
			return fmt.Sprint(r)
		}
		return string(b)
	}
}

func formatRecordMap(r map[string]any) string {
	ts, _ := r["ts"].(string)
	src, _ := r["src"].(string)
	ev, _ := r["ev"].(string)

	var dataStr string
	if d, ok := r["data"]; ok && d != nil {
		b, err := json.Marshal(d)
		if err == nil {
			dataStr = " " + string(b)
		}
	}

	var whyStr string
	if w, ok := r["why"].(string); ok && w != "" {
		whyStr = "  -- " + w
	}

	if ts == "" && src == "" && ev == "" {
		b, _ := json.Marshal(r)
		return string(b)
	}

	return fmt.Sprintf("%s [%s] %s%s%s", ts, src, ev, dataStr, whyStr)
}
