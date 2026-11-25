package forward

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

type closeWriter interface {
	CloseWrite() error
}

type readerConn struct {
	net.Conn
	r io.Reader
}

func (rc *readerConn) Read(p []byte) (int, error) {
	return rc.r.Read(p)
}

func (rc *readerConn) CloseWrite() error {
	if cw, ok := rc.Conn.(closeWriter); ok {
		return cw.CloseWrite()
	}
	return rc.Close()
}

func pipe(c1, c2 net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	cp := func(dst, src net.Conn) { defer wg.Done(); _, _ = io.Copy(dst, src); _ = c1.Close(); _ = c2.Close() }
	go cp(c1, c2)
	go cp(c2, c1)
	wg.Wait()
}

func serveSOCKS5(ctx context.Context, r io.Reader, conn net.Conn, dialer func(ctx context.Context, target string) (net.Conn, error)) {
	// Handshake: VER, NMETHODS, METHODS
	buf := make([]byte, 2)
	if _, err := io.ReadFull(r, buf); err != nil {
		return
	}
	ver, nMethods := buf[0], int(buf[1])
	if ver != 0x05 || nMethods <= 0 {
		return
	}
	methods := make([]byte, nMethods)
	if _, err := io.ReadFull(r, methods); err != nil {
		return
	}

	hasNoAuth := false
	for _, m := range methods {
		if m == 0x00 {
			hasNoAuth = true
			break
		}
	}
	if !hasNoAuth {
		_, _ = conn.Write([]byte{0x05, 0xFF}) // No acceptable methods
		return
	}
	if _, err := conn.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	// Request: VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT
	reqHead := make([]byte, 4)
	if _, err := io.ReadFull(r, reqHead); err != nil {
		return
	}
	if reqHead[0] != 0x05 || reqHead[2] != 0x00 {
		return
	}
	if reqHead[1] != 0x01 { // CMD != CONNECT
		_, _ = conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Command not supported
		return
	}

	atyp := reqHead[3]
	var host string
	switch atyp {
	case 0x01: // IPv4
		ipBuf := make([]byte, 4)
		if _, err := io.ReadFull(r, ipBuf); err != nil {
			return
		}
		host = net.IP(ipBuf).String()
	case 0x03: // Domain
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(r, lenBuf); err != nil {
			return
		}
		domLen := int(lenBuf[0])
		domBuf := make([]byte, domLen)
		if _, err := io.ReadFull(r, domBuf); err != nil {
			return
		}
		host = string(domBuf)
	case 0x04: // IPv6
		ipBuf := make([]byte, 16)
		if _, err := io.ReadFull(r, ipBuf); err != nil {
			return
		}
		host = net.IP(ipBuf).String()
	default:
		_, _ = conn.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Address type not supported
		return
	}

	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(r, portBuf); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(portBuf)
	target := net.JoinHostPort(host, strconv.Itoa(int(port)))

	up, err := dialer(ctx, target)
	if err != nil {
		_, _ = conn.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // Connection refused
		return
	}
	defer func() { _ = up.Close() }()

	if _, err := conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}

	pipe(&readerConn{Conn: conn, r: r}, up)
}

func serveDualProxy(ctx context.Context, conn net.Conn, pacBytes []byte, dialer func(ctx context.Context, target string) (net.Conn, error)) {
	br := bufio.NewReader(conn)
	peek, err := br.Peek(1)
	if err != nil {
		return
	}

	// SOCKS5 starts with byte 0x05
	if peek[0] == 0x05 {
		serveSOCKS5(ctx, br, conn, dialer)
		return
	}

	// HTTP Proxy or PAC request
	req, err := http.ReadRequest(br)
	if err != nil {
		_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return
	}

	defer func() { _ = req.Body.Close() }()
	// PAC script request
	if req.Method == http.MethodGet && strings.HasPrefix(req.URL.Path, "/lan.pac") {
		resp := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(pacBytes), string(pacBytes))
		_, _ = conn.Write([]byte(resp))
		return
	}

	// HTTP CONNECT method
	if req.Method == http.MethodConnect {
		target := req.RequestURI
		if target == "" {
			target = req.Host
		}
		if !strings.Contains(target, ":") {
			target = net.JoinHostPort(target, "443")
		}

		up, err := dialer(ctx, target)
		if err != nil {
			_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
			return
		}
		defer func() { _ = up.Close() }()

		if _, err := conn.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n")); err != nil {
			return
		}

		pipe(&readerConn{Conn: conn, r: br}, up)
		return
	}

	// Standard HTTP proxy request
	targetHost := req.URL.Hostname()
	targetPort := req.URL.Port()
	if targetPort == "" {
		if strings.EqualFold(req.URL.Scheme, "https") {
			targetPort = "443"
		} else {
			targetPort = "80"
		}
	}
	if targetHost == "" {
		targetHost = req.Host
	}
	if targetHost != "" && targetPort != "" {
		targetHost = net.JoinHostPort(targetHost, targetPort)
	}

	up, err := dialer(ctx, targetHost)
	if err != nil {
		_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return
	}
	defer func() { _ = up.Close() }()

	req.Header.Del("Proxy-Connection")
	req.Header.Del("Connection")
	req.Header.Set("Connection", "close")
	req.RequestURI = ""

	if err := req.Write(up); err != nil {
		return
	}

	pipe(&readerConn{Conn: conn, r: br}, up)
}
