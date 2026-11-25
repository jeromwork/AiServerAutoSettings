package vpnrun

import (
	"regexp"
	"strings"
)

// Обнаружение «мёртвого туннеля» по журналу sing-box (GET /logs, строки {"type":"...","payload":"..."}).
// sing-box жив, а узел выхода не отвечает: весь интернет ПК пропадает. Таймеров нет — считаем события.
//
// ВСЁ распознавание строк журнала — только здесь, в этом файле.

// deadErrors — сколько ошибок соединения через узел выхода подряд (без единого успешного соединения между ними)
// считаем смертью туннеля. 5: одиночные сбои (один сайт недоступен) не должны гасить VPN,
// а 5 подряд через один узел — уже не случайность. Времени в правиле нет: только счёт.
const deadErrors = 5

// logLevel — debug, а не info: признак успеха («connection ... finished») sing-box пишет только на уровне debug.
// Без него счётчик нечем было бы сбрасывать. Строки в память не складываются: хранятся лишь последние 3 ошибки.
const logLevel = "debug"

var (
	// ошибки dial/чтения через узел выхода: «... using outbound/vless[tag]: dial tcp ...: i/o timeout» и т.п.
	errWords = []string{"i/o timeout", "timeout", "connection refused", "connection reset", "EOF", "no route to host", "network is unreachable"}
	// успешное соединение: sing-box закрыл поток, по которому прошли данные.
	okWords = []string{"connection upload finished", "connection download finished", "connection closed"}
	// ошибка соединения вообще (не обязательно наш узел) начинается так, текст ошибки идёт после
	failMark = "open connection to"
)

// tunnelWatch считает ошибки подряд. Не потокобезопасен: им владеет один поток чтения журнала.
type tunnelWatch struct {
	tagRe *regexp.Regexp // outbound/<тип>[<тег узла выхода>]
	n     int
	last  []string // последние 3 строки ошибок
}

func newTunnelWatch(exitTag string) *tunnelWatch {
	return &tunnelWatch{tagRe: regexp.MustCompile(`outbound/[A-Za-z0-9_-]+\[` + regexp.QuoteMeta(exitTag) + `\]`)}
}

// feed разбирает одну строку журнала; true — туннель мёртв (deadErrors ошибок подряд).
func (w *tunnelWatch) feed(payload string) bool {
	for _, ok := range okWords {
		if strings.Contains(payload, ok) {
			w.n, w.last = 0, nil
			return false
		}
	}
	if !w.tagRe.MatchString(payload) || !strings.Contains(payload, failMark) {
		return false
	}
	for _, e := range errWords {
		if strings.Contains(payload, e) {
			w.n++
			if len(payload) > 200 {
				payload = payload[:200]
			}
			w.last = append(w.last, payload)
			if len(w.last) > 3 {
				w.last = w.last[1:]
			}
			return w.n >= deadErrors
		}
	}
	return false
}
