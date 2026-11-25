package forward

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const headMax = 16384

var (
	replyFail  = []byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0}
	replyNoCmd = []byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0}
	replyOK    = []byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	httpURL    = regexp.MustCompile(`(?i)^http://([^/:]+)(?::(\d+))?(/.*)?$`)
	dropHdr    = regexp.MustCompile(`(?i)^(proxy-connection|connection):`)
)

// pipe: пока идёт хоть одно направление; конец любого закрывает оба сокета (как v2).
func pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	one := func(x, y net.Conn) {
		defer wg.Done()
		io.Copy(y, x)
		x.Close()
		y.Close()
	}
	go one(b, a)
	one(a, b)
	wg.Wait()
}

// bufConn читает через bufio (после PEEK первого байта), пишет напрямую.
type bufConn struct {
	net.Conn
	r *bufio.Reader
}

func (b *bufConn) Read(p []byte) (int, error) { return b.r.Read(p) }

// open: хост из сетей ЛВС — через канал, остальное — напрямую.
func (f *fwd) open(s *sess, host string, port int) (net.Conn, error) {
	var up net.Conn
	var err error
	if n := match(f.nets, host); n != "" {
		if up, err = f.dial(host, port); err != nil {
			return nil, err
		}
		f.log.Info("lan", "net", n, "target", net.JoinHostPort(host, strconv.Itoa(port)))
	} else if up, err = net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 10*time.Second); err != nil {
		return nil, err
	}
	s.reg(up)
	return up, nil
}

// internalSocks: SOCKS5 поверх канала для sing-box LAN — всё идёт через канал.
func (f *fwd) internalSocks(c net.Conn, s *sess) error {
	return f.socks5(&bufConn{c, bufio.NewReader(c)}, s, func(h string, p int) (net.Conn, error) {
		up, err := f.dial(h, p)
		if err == nil {
			s.reg(up)
		}
		return up, err
	})
}

// socks5: без авторизации, только CONNECT.
func (f *fwd) socks5(c net.Conn, s *sess, open func(string, int) (net.Conn, error)) error {
	var b [4]byte
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return err
	}
	if _, err := io.CopyN(io.Discard, c, int64(b[1])); err != nil {
		return err
	}
	c.Write([]byte{5, 0})
	if _, err := io.ReadFull(c, b[:4]); err != nil {
		return err
	}
	if b[1] != 1 {
		c.Write(replyNoCmd)
		return nil
	}
	var host string
	switch b[3] {
	case 1, 4:
		ip := make([]byte, map[byte]int{1: 4, 4: 16}[b[3]])
		if _, err := io.ReadFull(c, ip); err != nil {
			return err
		}
		host = net.IP(ip).String()
	default:
		if _, err := io.ReadFull(c, b[:1]); err != nil {
			return err
		}
		name := make([]byte, b[0])
		if _, err := io.ReadFull(c, name); err != nil {
			return err
		}
		host = string(name)
	}
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return err
	}
	port := int(binary.BigEndian.Uint16(b[:2]))
	up, err := open(host, port)
	if err != nil {
		c.Write(replyFail)
		f.refuse(host, err)
		return nil
	}
	c.Write(replyOK)
	pipe(c, up)
	return nil
}

func (f *fwd) proxy(c net.Conn, s *sess, port int) error {
	br := bufio.NewReader(c)
	first, err := br.Peek(1)
	if err != nil {
		return nil
	}
	bc := &bufConn{c, br}
	if first[0] == 5 {
		return f.socks5(bc, s, func(h string, p int) (net.Conn, error) { return f.open(s, h, p) })
	}
	var head []byte
	buf := make([]byte, 4096)
	for !bytes.Contains(head, []byte("\r\n\r\n")) && len(head) < headMax {
		n, err := bc.Read(buf)
		if n == 0 && err != nil {
			return nil
		}
		head = append(head, buf[:n]...)
	}
	hdr, rest, _ := bytes.Cut(head, []byte("\r\n\r\n"))
	lines := strings.Split(string(hdr), "\r\n")
	parts := append(strings.Split(lines[0], " "), "", "", "")
	method, tgt, ver := parts[0], parts[1], parts[2]
	if method == "GET" && strings.HasPrefix(tgt, "/lan.pac") {
		f.mu.Lock()
		body := pacText(f.nets, port)
		f.mu.Unlock()
		fmt.Fprintf(c, "HTTP/1.0 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: %d\r\n\r\n%s", len(body), body)
		return nil
	}
	bad := "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
	if method == "CONNECT" {
		i := strings.LastIndex(tgt, ":")
		p, perr := strconv.Atoi(tgt[i+1:])
		if i < 0 || perr != nil {
			c.Write([]byte(bad))
			return f.refusal(tgt, errors.New("плохой порт"))
		}
		up, err := f.open(s, strings.Trim(tgt[:i], "[]"), p)
		if err != nil {
			c.Write([]byte(bad))
			return f.refusal(tgt, err)
		}
		c.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
		if len(rest) > 0 {
			up.Write(rest)
		}
		pipe(bc, up)
		return nil
	}
	m := httpURL.FindStringSubmatch(tgt)
	if m == nil {
		c.Write([]byte("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"))
		return nil
	}
	p, path := 80, m[3]
	if m[2] != "" {
		p, _ = strconv.Atoi(m[2])
	}
	if path == "" {
		path = "/"
	}
	up, err := f.open(s, m[1], p)
	if err != nil {
		c.Write([]byte(bad))
		return f.refusal(tgt, err)
	}
	if ver == "" {
		ver = "HTTP/1.1"
	}
	var req bytes.Buffer
	fmt.Fprintf(&req, "%s %s %s\r\n", method, path, ver)
	for _, l := range lines[1:] {
		if !dropHdr.MatchString(l) {
			req.WriteString(l + "\r\n")
		}
	}
	req.WriteString("Connection: close\r\n\r\n")
	req.Write(rest)
	up.Write(req.Bytes())
	pipe(bc, up)
	return nil
}

func (f *fwd) refusal(what string, err error) error {
	f.refuse(what, err)
	return nil
}
