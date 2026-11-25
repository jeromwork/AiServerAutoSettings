package vpnrun

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync/atomic"
	"time"
)

// Обнаружение «мёртвого туннеля»: ошибка соединения через узел выхода в журнале sing-box (GET /logs,
// строки {"type":"...","payload":"..."}) — это только ПОВОД для одной контрольной проверки; решает проверка.
// Почему не счёт ошибок и не маленький запрос: ТСПУ пропускает первые 16-33 КБ соединения и потом его замораживает,
// поэтому 204/HEAD даёт ложное «жив». Проверка качает ровно 64 КиБ (см. ~/work/briefs/dpi-probe-research.result.md).
// Таймеров и периодических проверок нет: проверка запускается только событием.
//
// ВСЁ распознавание строк журнала — только здесь, в этом файле.

const (
	// logLevel: ошибки соединений sing-box пишет уже на info; debug был нужен лишь для признаков успеха прежнего счётчика.
	logLevel = "info"
	// DefaultProbeURL — адрес, отдающий ровно probeBytes несжимаемых байт.
	DefaultProbeURL = "https://speed.cloudflare.com/__down?bytes=65536"
	probeBytes      = 65536
	// probeTimeout — предел одной проверки (таймаут одного действия, не периодика).
	probeTimeout = 10 * time.Second
)

var (
	// ошибки dial/чтения через узел выхода: «... using outbound/vless[tag]: dial tcp ...: i/o timeout» и т.п.
	errWords = []string{"i/o timeout", "timeout", "connection refused", "connection reset", "EOF", "no route to host", "network is unreachable"}
	// ошибка соединения вообще (не обязательно наш узел) начинается так, текст ошибки идёт после
	failMark = "open connection to"
)

// tunnelWatch ищет в журнале ошибки соединения и не пускает вторую проверку, пока идёт первая.
// feed вызывается одним потоком чтения журнала; probing разделяется с горутиной проверки.
type tunnelWatch struct {
	tagRe   *regexp.Regexp // outbound/<тип>[<тег узла выхода>]
	probing atomic.Bool
	last    []string // последние 3 строки ошибок (только поток журнала)
}

func newTunnelWatch(exitTags []string) *tunnelWatch {
	tags := make([]string, 0, len(exitTags))
	for _, tag := range exitTags {
		tags = append(tags, regexp.QuoteMeta(tag))
	}
	return &tunnelWatch{tagRe: regexp.MustCompile(`outbound/[A-Za-z0-9_-]+\[(?:` + strings.Join(tags, "|") + `)\]`)}
}

// feed разбирает одну строку журнала; true — это ошибка соединения через узел выхода и проверка ещё не идёт:
// вызывающий обязан запустить ровно одну проверку и после успеха вызвать w.probing.Store(false).
func (w *tunnelWatch) feed(payload string) bool {
	if !w.tagRe.MatchString(payload) || !strings.Contains(payload, failMark) {
		return false
	}
	for _, e := range errWords {
		if strings.Contains(payload, e) {
			if len(payload) > 200 {
				payload = payload[:200]
			}
			w.last = append(w.last, payload)
			if len(w.last) > 3 {
				w.last = w.last[1:]
			}
			return w.probing.CompareAndSwap(false, true)
		}
	}
	return false
}

// probe: один GET через туннель (трафик ПК и так идёт в TUN) без сжатия; жив, только если прочитано ровно probeBytes.
func probe(ctx context.Context, url string) error {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept-Encoding", "identity")
	cl := &http.Client{Transport: &http.Transport{Proxy: nil, DisableCompression: true, DisableKeepAlives: true}}
	resp, err := cl.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("probe status %d", resp.StatusCode)
	}
	n, err := io.Copy(io.Discard, io.LimitReader(resp.Body, probeBytes+1))
	if err != nil {
		return fmt.Errorf("probe read after %d bytes: %w", n, err)
	}
	if n != probeBytes {
		return fmt.Errorf("probe got %d bytes, want %d", n, probeBytes)
	}
	return nil
}
